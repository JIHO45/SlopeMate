import CoreLocation
import CoreMotion
import Foundation
import Observation

/// 기록 엔진 (R2, R4, R18, 05-design 3장·7장).
@Observable
final class Recorder: NSObject, CLLocationManagerDelegate {
    enum Blocked: Equatable { case servicesOff, denied, reducedAccuracy }
    enum Status: Equatable { case idle, recording, paused(Blocked), failed(String) }

    var status: Status = .idle
    var recording: Recording?
    var points: [Point] = []
    /// 기록 시작 전 막힌 이유
    var blocked: Blocked?
    /// S7: 사용자가 직접 연 앱에서 끝나지 않은 기록을 이어갈지 묻는다
    var pendingResume: Recording?
    /// 자동 재개했을 때 화면에 알릴 내용: 끊겼던 시간(초)
    var autoResumedGap: TimeInterval?
    var todayRecordings: [Recording] = []
    private var earlierToday = RunDetector.Summary()

    let db: AppDatabase
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let altimeter = CMAltimeter()
    @ObservationIgnored private var session: CLBackgroundActivitySession?
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var lastBaro: (alt: Double, t: Date)?
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var seqStartedAt = Date.distantPast
    @ObservationIgnored private var pendingStartResort: String?

    /// 오늘(영업일) 합계: 끝난 기록 + 진행 중 기록
    var today: RunDetector.Summary { earlierToday + RunDetector.detect(points) }

    /// 이보다 짧게 끊긴 기록은 묻지 않고 이어서 기록한다 (decisions 2026-11-08)
    static let autoResumeLimit: TimeInterval = 10 * 60

    static let storageFailedKey = "storageFailedRecording"

    static var lastResortId: String? { UserDefaults.standard.string(forKey: "lastResortId") }

    static var lowStorage: Bool {
        let v = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return (v?.volumeAvailableCapacityForImportantUsage ?? .max) < 100_000_000
    }

    init(db: AppDatabase) {
        self.db = db
        super.init()
        manager.delegate = self
        loadToday()
    }

    // MARK: 시작·종료

    func start(resortId: String) {
        guard recording == nil else { return }
        if manager.authorizationStatus == .notDetermined {
            pendingStartResort = resortId
            manager.requestWhenInUseAuthorization()
            return
        }
        blocked = authProblem()
        guard blocked == nil else { return }
        do {
            let rec = try db.createRecording(resortId: resortId, at: .now)
            UserDefaults.standard.set(resortId, forKey: "lastResortId")
            recording = rec
            points = []
            seq = 0
            loadToday()
            beginUpdates()
        } catch {
            status = .failed("기록을 시작하지 못했어요. \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let rec = recording else { return }
        autoResumedGap = nil
        stopUpdates()
        do { try db.end(rec, at: .now, reason: "user") } catch {
            // 끝난 표시를 못 남겨도 위치점은 남아 있다. 다음 실행 때 끊긴 기록으로 처리된다.
            status = .failed("기록 종료를 저장하지 못했어요. \(error.localizedDescription)")
            return
        }
        recording = nil
        points = []
        status = .idle
        loadToday()
    }

    // MARK: 미완료 기록 (05-design 7장)

    /// 앱이 실행될 때 한 번. 끝나지 않은 기록이 있으면:
    /// - 위치 이벤트로 다시 실행됐거나, 같은 영업일에 기준 시간 안으로 끊겼으면 묻지 않고 이어서 기록하고 화면에 알린다
    /// - 권한 때문에 멈춰 있던 기록, 오래 끊긴 기록은 S7로 묻는다
    /// - 영업일이 지났으면 끊긴 기록으로 끝낸다
    /// 사용자가 종료한 기록은 끝난 기록이라 여기 오지 않는다.
    func handleLaunch(locationRelaunch: Bool, now: Date = .now) {
        let storageFailed = UserDefaults.standard.string(forKey: Self.storageFailedKey)
        let rec: Recording?
        let file: RecordingFile?
        do {
            rec = try db.unfinished()
            file = try rec.map(db.file)
        } catch { status = .failed("기록을 읽지 못했어요. \(error.localizedDescription)"); return }
        guard let rec, let file else { return }
        let last = file.points.last?.t ?? rec.startedAt
        let pausedByPermission = file.gaps.contains { $0.toT == nil && $0.reason == "permission" }
        guard BusinessDay.same(rec.startedAt, now) else { return endInterrupted(rec, now: now) }
        let autoOK = !pausedByPermission && storageFailed != rec.id.uuidString
        if autoOK && (locationRelaunch || now.timeIntervalSince(last) <= Self.autoResumeLimit) {
            resume(rec, reason: locationRelaunch ? "system" : "auto", now: now)
            autoResumedGap = now.timeIntervalSince(last)
        } else {
            pendingResume = rec
        }
    }

    func answerResume(_ yes: Bool) {
        guard let rec = pendingResume else { return }
        pendingResume = nil
        if yes { resume(rec, reason: "user", now: .now) } else { endInterrupted(rec, now: .now) }
    }

    private func resume(_ rec: Recording, reason: String, now: Date) {
        UserDefaults.standard.removeObject(forKey: Self.storageFailedKey)
        do {
            recording = rec
            points = try db.points(rec)
            loadToday()
            if let b = authProblem() ?? (manager.authorizationStatus == .notDetermined ? .denied : nil) {
                try db.openGap(rec, reason: "permission", at: now)
                status = .paused(b)
                return
            }
            seq = try db.restart(rec, reason: reason, at: now)
            beginUpdates()
        } catch {
            status = .failed("기록을 이어가지 못했어요. \(error.localizedDescription)")
        }
    }

    private func endInterrupted(_ rec: Recording, now: Date) {
        do { try db.endInterrupted(rec, now: now) } catch { status = .failed("끊긴 기록을 정리하지 못했어요. \(error.localizedDescription)") }
        loadToday()
    }

    // MARK: 수신

    private func beginUpdates() {
        session = CLBackgroundActivitySession()
        lastBaro = nil
        seqStartedAt = .now
        if CMAltimeter.isRelativeAltitudeAvailable() {
            // 상대고도는 시작할 때마다 0부터. seq가 바뀔 때만 다시 시작한다.
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self else { return }
                if let data {
                    self.lastBaro = (data.relativeAltitude.doubleValue, .now)
                } else {
                    // 권한 거부 등: 이 seq의 나머지는 GPS 고도로 판정된다
                    self.altimeter.stopRelativeAltitudeUpdates()
                    self.lastBaro = nil
                }
            }
        }
        status = .recording
        updates = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                    guard let self, !Task.isCancelled else { return }
                    if let loc = update.location { self.save(loc) }
                }
            } catch {}
            // 스트림이 스스로 끝나면 조용히 "기록 중"으로 두지 않는다(R4)
            guard let self, !Task.isCancelled, self.status == .recording else { return }
            self.stopUpdates()
            self.status = .failed("위치 수신이 멈췄어요. 기록을 종료한 뒤 다시 시작해 주세요. 여기까지의 기록은 남아 있어요.")
        }
    }

    private func stopUpdates() {
        updates?.cancel()
        updates = nil
        session?.invalidate()
        session = nil
        altimeter.stopRelativeAltitudeUpdates()
        lastBaro = nil
    }

    /// 받는 즉시 저장. 저장에 실패하면 조용히 계속하지 않고 기록을 멈춘다(R4).
    func save(_ loc: CLLocation) {
        guard let rec = recording, status == .recording else { return }
        // 수신을 시작할 때 오는 캐시된 옛 위치는 버린다
        guard loc.timestamp >= seqStartedAt, loc.timestamp > (points.last?.t ?? .distantPast) else { return }
        var p = Point(recordingId: rec.id, t: loc.timestamp, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                      hAcc: loc.horizontalAccuracy, gpsAlt: loc.altitude, vAcc: loc.verticalAccuracy, speed: loc.speed,
                      baroAlt: lastBaro?.alt, baroT: lastBaro?.t, seq: seq)
        do {
            try db.insert(&p)
            points.append(p)
        } catch {
            stopUpdates()
            do { try db.end(rec, at: .now, reason: "storage") } catch {
                // 끝난 표시도 못 남겼으면 다음 실행 때 자동으로 이어가지 않게 표시해 둔다
                UserDefaults.standard.set(rec.id.uuidString, forKey: Self.storageFailedKey)
            }
            recording = nil
            points = []
            status = .failed("저장하지 못해 기록을 멈췄어요. 저장 공간을 확인해 주세요. 여기까지의 기록은 남아 있어요.")
            loadToday()
        }
    }

    // MARK: 권한 (R18)

    private func authProblem() -> Blocked? {
        switch manager.authorizationStatus {
        case .notDetermined: return nil
        case .denied, .restricted: return CLLocationManager.locationServicesEnabled() ? .denied : .servicesOff
        default: return manager.accuracyAuthorization == .reducedAccuracy ? .reducedAccuracy : nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.authChanged() }
    }

    private func authChanged() {
        if let r = pendingStartResort, manager.authorizationStatus != .notDetermined {
            pendingStartResort = nil
            start(resortId: r)
            return
        }
        if recording == nil {
            if blocked != nil { blocked = authProblem() }
            return
        }
        guard let rec = recording else { return }
        do {
            switch (status, authProblem()) {
            case (.recording, let b?):
                stopUpdates()
                try db.openGap(rec, reason: "permission", at: .now)
                status = .paused(b)
            case (.paused, nil):
                seq = try db.restart(rec, reason: "permission", at: .now)
                beginUpdates()
            default: break
            }
        } catch {
            status = .failed("기록 상태를 저장하지 못했어요. \(error.localizedDescription)")
        }
    }

    // MARK: 오늘

    private func loadToday() {
        do {
            todayRecordings = try db.recordings(since: BusinessDay.start(of: .now))
            earlierToday = try todayRecordings.filter { $0.id != recording?.id }
                .map { RunDetector.detect(try db.points($0)) }
                .reduce(RunDetector.Summary(), +)
        } catch {
            status = .failed("기록을 읽지 못했어요. \(error.localizedDescription)")
        }
    }
}
