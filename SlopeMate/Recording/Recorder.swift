import UIKit
import CoreLocation
import CoreMotion
import Foundation
import GRDB
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
    /// S3에서 골랐지만 위치 권한을 기다리는 리조트 (S4). 권한이 생기면 이 리조트로 시작한다.
    var pendingStart: String?
    /// 기다리던 시작에 S4가 필요한지(위치 권한 미결정·거부·정확한 위치 꺼짐·위치 서비스 꺼짐). 권한이 이미 있으면 S4 없이 바로.
    var needsLocation = false
    /// 첫 기록: 권한까지 끝났고 익명 표본 동의 답을 기다린다(R12, decisions 2026-11-12 첫 기록 순서)
    var awaitingConsent = false
    /// 영업일 끝에 닫은 기록 (S7 영업일 끝 v2). 다음 실행에도 알리고, 확인하면 지운다.
    var dayEndNotice: Recording?
    /// S7: 사용자가 직접 연 앱에서 끝나지 않은 기록을 이어갈지 묻는다
    var pendingResume: Recording?
    /// 자동 재개했을 때 화면에 알릴 내용: 끊겼던 시간(초)
    var autoResumedGap: TimeInterval?
    /// 자동 재개 전 마지막 위치 시각 (끊긴 구간의 시작, S5 배너)
    var autoResumedFrom: Date?
    var todayRecordings: [Recording] = []
    private var earlierToday = RunDetector.Summary()
    /// 진행 중 기록의 차량 구간 (R49)
    var vehicle: [DateInterval] = []

    let db: AppDatabase
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let altimeter = CMAltimeter()
    @ObservationIgnored private let activity = CMMotionActivityManager()
    /// 지금 차량 이동 중이면 그 시작 시각 (R49 실시간)
    @ObservationIgnored private var vehicleSince: Date?
    @ObservationIgnored private var session: CLBackgroundActivitySession?
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var lastBaro: (alt: Double, t: Date)?
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var seqStartedAt = Date.distantPast
    /// 위치 다음 동작 및 피트니스 권한을 묻는 중
    @ObservationIgnored private var askingMotion = false
    /// 이번 시작 시도에서 동작 및 피트니스를 이미 물었다(응답이 이상해도 다시 묻지 않는다)
    @ObservationIgnored private var motionAsked = false
    @ObservationIgnored private var askedLocationNow = false
    @ObservationIgnored private var lastAlertCheck = Date.distantPast
    /// Live Activity (R23)
    @ObservationIgnored private let live = LiveRecording()
    @ObservationIgnored private var lastLiveCheck = Date.distantPast

    /// 오늘(영업일) 합계: 끝난 기록 + 진행 중 기록
    var today: RunDetector.Summary { earlierToday + RunDetector.detect(points, vehicle: currentVehicle()) }

    /// 설질 질문 칸에 물을 하강 (R11). 진행 중 기록만 본다.
    var snowTarget: RunDetector.Run? {
        guard let rec = recording else { return nil }
        return SnowPrompt.target(RunDetector.detect(points, vehicle: currentVehicle()), points: points,
                                 map: SlopeMap.cached(resortId: rec.resortId), now: .now)
    }

    func rateSnow(_ value: SnowRating.Value) {
        guard let rec = recording, let run = snowTarget else { return }
        _ = try? db.rate(rec, run: run, value: value, now: .now)
    }

    /// 저장된 차량 구간 + 지금 이어지는 차량 이동
    private func currentVehicle(now: Date = .now) -> [DateInterval] {
        vehicle + (vehicleSince.map { [DateInterval(start: $0, end: max($0, now))] } ?? [])
    }

    /// 이보다 짧게 끊긴 기록은 묻지 않고 이어서 기록한다 (decisions 2026-11-08)
    static let autoResumeLimit: TimeInterval = 10 * 60

    static let storageFailedKey = "storageFailedRecording"
    static let dayEndKey = "dayEndNotice"

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
        if let id = UserDefaults.standard.string(forKey: Self.dayEndKey).flatMap(UUID.init) {
            dayEndNotice = try? db.queue.read { try Recording.fetchOne($0, key: id) }
        }
        // 알림을 나중에 허용하면(설정 줄·알림 카드) 기록 중 60분·5km 알림을 처음부터 다시 정한다
        NotificationCenter.default.addObserver(forName: ForgottenStop.granted, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.alertsPermissionGranted() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
    }

    // MARK: 시작·종료

    /// S3 다음. 순서는 권한(S4: 위치 → 동작) → 첫 기록이면 익명 표본 동의 → 시작(R12, R18, R51).
    func requestStart(resortId: String) {
        guard recording == nil else { return }
        pendingStart = resortId
        motionAsked = false
        askedLocationNow = false
        awaitingConsent = false
        blocked = authProblem()
        needsLocation = blocked != nil || manager.authorizationStatus == .notDetermined
        startPending()
    }

    /// S4를 닫거나 이번 창에서 위치를 거부함: 기다리던 시작을 버린다
    func cancelPendingStart() {
        pendingStart = nil
        awaitingConsent = false
        askedLocationNow = false
    }

    /// S4 "계속": iOS 위치 권한 창
    func requestPermission() {
        if manager.authorizationStatus == .notDetermined { askedLocationNow = true }
        manager.requestWhenInUseAuthorization()
    }

    /// 동의 시트에 답한 뒤(저장에 실패해도 물은 것으로 남는다) 시작을 잇는다
    func consentAnswered() {
        awaitingConsent = false
        startPending()
    }

    /// 방금 뜬 iOS 창에서 위치를 거부했으면 뒤의 질문 없이 홈으로(04-flows S4 순서). 정확한 위치만 끈 것은 거부가 아니라 S4에 남는다.
    private func cancelIfDeniedNow() {
        if askedLocationNow, pendingStart != nil, authProblem() == .denied { cancelPendingStart() }
    }

    /// 기다리던 시작: 위치 권한이 있으면 동작 및 피트니스 권한을 (처음이면) 물은 뒤 시작한다. 여러 번 불려도 한 번만 시작한다.
    private func startPending() {
        guard let r = pendingStart, recording == nil, !askingMotion,
              manager.authorizationStatus != .notDetermined, authProblem() == nil else { return }
        if !motionAsked, CMMotionActivityManager.isActivityAvailable(), CMMotionActivityManager.authorizationStatus() == .notDetermined {
            askingMotion = true
            motionAsked = true
            // 거부해도 기록은 시작한다(GPS 고도로 대신 잼)
            activity.queryActivityStarting(from: .now, to: .now, to: .main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.askingMotion = false
                    self?.startPending()
                }
            }
            return
        }
        if !Settings.consentAsked {
            awaitingConsent = true
            return
        }
        pendingStart = nil
        start(resortId: r)
    }

    func start(resortId: String) {
        guard recording == nil else { return }
        blocked = authProblem()
        guard blocked == nil, manager.authorizationStatus != .notDetermined else { return }
        do {
            let rec = try db.createRecording(resortId: resortId, at: .now)
            UserDefaults.standard.set(resortId, forKey: "lastResortId")
            recording = rec
            points = []
            vehicle = []
            autoResumedGap = nil
            autoResumedFrom = nil
            seq = 0
            loadToday()
            beginUpdates()
            // 알림 권한은 시작 때 묻지 않고 S5 카드·설정 줄에서(R49, decisions 2026-11-13)
            updateAlerts(force: true)
        } catch {
            status = .failed("기록을 시작하지 못했어요. \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let rec = recording else { return }
        stopUpdates()
        do { try db.end(rec, at: .now, reason: "user") } catch {
            // 끝난 표시를 못 남겨도 위치점은 남아 있다. 다음 실행 때 끊긴 기록으로 처리된다.
            status = .failed("기록 종료를 저장하지 못했어요. \(error.localizedDescription)")
            showLive()
            return
        }
        finished(rec)
    }

    /// 기록이 끝난 뒤 정리: 알림을 지우고, 차량 구간을 조회한다(활동 기록이 늦게 들어오면 다음 실행 때 다시 조회).
    private func finished(_ rec: Recording) {
        // 카드에는 저장된 종료 시각과 그날 합계를 보여준다. 복구 화면에서 끝낸 기록은 저장된 기록으로 합계를 만든다.
        let stored = (try? db.queue.read { try Recording.fetchOne($0, key: rec.id) }) ?? rec
        var final = recording?.id == rec.id ? liveState() : nil
        if final == nil, live.hasCard(rec.id) {
            // 일반 종료와 같은 기준: 그 영업일의 모든 리조트 합계
            let date = BusinessDay.start(of: stored.startedAt)
            let runs = ((try? HomeData.days(db, since: date)) ?? []).filter { $0.date == date }.flatMap(\.runs)
            final = .init(startedAt: stored.startedAt, runs: runs.count, distance: runs.reduce(0) { $0 + $1.distance })
        }
        live.end(recordingId: rec.id, final, endedAt: stored.endedAt ?? .now)
        ForgottenStop.scheduleIdle(at: nil)
        ForgottenStop.setFarSent(rec, nil)
        ForgottenStop.setIdleDeadline(rec, nil)
        if recording?.id == rec.id {
            // 끝난 기록의 저장된 결과가 준비될 때까지는 방금까지 보이던 합계를 유지한다
            earlierToday = today
            recording = nil
            points = []
            vehicle = []
            autoResumedGap = nil
            autoResumedFrom = nil
            status = .idle
        }
        // 방금 끝난 기록의 하루 계산(전체 위치점 판정·경로)은 메인 스레드 밖에서 만든 뒤 합계를 다시 읽는다
        let db = db
        Task { [weak self] in
            await Task.detached(priority: .userInitiated) { _ = try? db.cache(rec, map: SlopeMap.load(resortId: rec.resortId)) }.value
            guard let self else { return }
            self.loadToday()
            self.refreshVehicle(rec)
            self.refreshCaches()
        }
    }

    /// 영업일 끝이 지난 기록은 마지막 위치점 시각으로 끝낸다(R49).
    private func closeAtDayEnd(_ rec: Recording) {
        if recording?.id == rec.id { stopUpdates() }
        do { try db.endAtLastPoint(rec, reason: "dayEnd") } catch {
            status = .failed("기록을 정리하지 못했어요. \(error.localizedDescription)")
            return
        }
        UserDefaults.standard.set(rec.id.uuidString, forKey: Self.dayEndKey)
        dayEndNotice = (try? db.queue.read { try Recording.fetchOne($0, key: rec.id) }) ?? rec
        finished(rec)
    }

    /// 영업일 끝 안내를 확인했다
    func acknowledgeDayEnd() {
        UserDefaults.standard.removeObject(forKey: Self.dayEndKey)
        dayEndNotice = nil
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
        defer { refreshVehicles() }
        guard BusinessDay.same(rec.startedAt, now) else { return closeAtDayEnd(rec) }
        let autoOK = !pausedByPermission && storageFailed != rec.id.uuidString
        if autoOK && (locationRelaunch || now.timeIntervalSince(last) <= Self.autoResumeLimit) {
            resume(rec, reason: locationRelaunch ? "system" : "auto", now: now)
            autoResumedGap = now.timeIntervalSince(last)
            autoResumedFrom = last
        } else {
            pendingResume = rec
        }
    }

    /// S7 답. 묻는 동안 06:00이 지났으면 답과 관계없이 영업일 끝으로 닫는다(영업일 끝 안내가 뜬다).
    func answerResume(_ yes: Bool, now: Date = .now) {
        guard let rec = pendingResume else { return }
        pendingResume = nil
        guard BusinessDay.same(rec.startedAt, now) else { return closeAtDayEnd(rec) }
        if yes { resume(rec, reason: "user", now: now) } else { endInterrupted(rec, now: now) }
    }

    private func resume(_ rec: Recording, reason: String, now: Date) {
        UserDefaults.standard.removeObject(forKey: Self.storageFailedKey)
        do {
            recording = rec
            points = try db.points(rec)
            vehicle = try db.vehicle(rec)
            loadToday()
            if let b = authProblem() ?? (manager.authorizationStatus == .notDetermined ? .denied : nil) {
                try db.openGap(rec, reason: "permission", at: now)
                status = .paused(b)
                showLive()
                return
            }
            seq = try db.restart(rec, reason: reason, at: now)
            beginUpdates()
            updateAlerts(force: true, now: now)
        } catch {
            status = .failed("기록을 이어가지 못했어요. \(error.localizedDescription)")
        }
    }

    private func endInterrupted(_ rec: Recording, now: Date) {
        do { try db.endInterrupted(rec, now: now) } catch {
            status = .failed("끊긴 기록을 정리하지 못했어요. \(error.localizedDescription)")
            return
        }
        finished(rec)
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
        // 차량 이동을 실시간으로 받는다(R49). 기록 중에는 위치 세션으로 앱이 살아 있어 백그라운드에서도 온다.
        vehicleSince = nil
        if CMMotionActivityManager.isActivityAvailable(), CMMotionActivityManager.authorizationStatus() == .authorized {
            activity.startActivityUpdates(to: .main) { [weak self] a in
                guard let self, let a else { return }
                self.activityChanged(start: a.startDate, automotive: a.automotive && a.confidence != .low)
            }
        }
        status = .recording
        showLive()
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
            self.showLive()
        }
    }

    private func stopUpdates() {
        updates?.cancel()
        updates = nil
        session?.invalidate()
        session = nil
        altimeter.stopRelativeAltitudeUpdates()
        lastBaro = nil
        activity.stopActivityUpdates()
        if let start = vehicleSince { addVehicle(DateInterval(start: start, end: max(start, .now))) }
        vehicleSince = nil
    }

    /// 받는 즉시 저장. 저장에 실패하면 조용히 계속하지 않고 기록을 멈춘다(R4).
    func save(_ loc: CLLocation) {
        guard let rec = recording, status == .recording else { return }
        // 영업일 끝이 지난 첫 위치: 저장하지 않고 기록을 닫는다(R49)
        if loc.timestamp >= BusinessDay.end(of: rec.startedAt) { return closeAtDayEnd(rec) }
        // 수신을 시작할 때 오는 캐시된 옛 위치는 버린다
        guard loc.timestamp >= seqStartedAt, loc.timestamp > (points.last?.t ?? .distantPast) else { return }
        var p = Point(recordingId: rec.id, t: loc.timestamp, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                      hAcc: loc.horizontalAccuracy, gpsAlt: loc.altitude, vAcc: loc.verticalAccuracy, speed: loc.speed,
                      baroAlt: lastBaro?.alt, baroT: lastBaro?.t, seq: seq)
        do {
            if DebugFailures.on("-SMFailSave") { throw DebugFailures.Injected() }
            try db.insert(&p)
            points.append(p)
            updateAlerts()
            if loc.timestamp.timeIntervalSince(lastLiveCheck) >= 10, let s = liveState() {
                lastLiveCheck = loc.timestamp
                live.update(s)
            }
        } catch {
            stopUpdates()
            live.end(recordingId: rec.id, liveState(stopped: "저장 공간이 부족해 기록이 멈췄어요. 앱을 열어 확인해 주세요"), endedAt: points.last?.t ?? .now)
            do { try db.end(rec, at: .now, reason: "storage") } catch {
                // 끝난 표시도 못 남겼으면 다음 실행 때 자동으로 이어가지 않게 표시해 둔다
                UserDefaults.standard.set(rec.id.uuidString, forKey: Self.storageFailedKey)
            }
            // finished()와 같이 60분 알림 예약과 기록별 알림 표시를 지운다
            ForgottenStop.scheduleIdle(at: nil)
            ForgottenStop.setFarSent(rec, nil)
            ForgottenStop.setIdleDeadline(rec, nil)
            recording = nil
            points = []
            loadToday() // 여기서 읽기도 실패하면 상태를 바꾸므로 저장 공간 안내보다 먼저 부른다
            status = .failed("저장하지 못해 기록을 멈췄어요. 마지막으로 저장된 기록은 ‘하루 기록 보기’에서 확인할 수 있어요. 기기 저장 공간이 부족해요. 공간을 비운 뒤 다시 시작하세요")
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
        if recording == nil {
            if blocked != nil || pendingStart != nil { blocked = authProblem() }
            cancelIfDeniedNow()
            startPending()
            return
        }
        guard let rec = recording else { return }
        do {
            switch (status, authProblem()) {
            case (.recording, let b?):
                stopUpdates()
                try db.openGap(rec, reason: "permission", at: .now)
                status = .paused(b)
                showLive()
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
                .map { rec in
                    let map = SlopeMap.cached(resortId: rec.resortId)
                    // 끝나지 않은 기록(S7 대기)은 저장된 결과가 없다
                    return rec.endedAt == nil ? RunDetector.detect(try db.points(rec), vehicle: try db.vehicle(rec), map: map)
                        : try db.cache(rec, map: map).summary
                }
                .reduce(RunDetector.Summary(), +)
        } catch {
            // 기록 중에는 합계를 못 읽어도 위치 저장은 계속한다(R4). .failed면 save()가 점을 버린다.
            if recording == nil { status = .failed("기록을 읽지 못했어요. \(error.localizedDescription)") }
        }
    }

    // MARK: 종료를 잊은 기록 (R49)

    private func alertsPermissionGranted() {
        guard let rec = recording else { return }
        ForgottenStop.setIdleDeadline(rec, nil)
        ForgottenStop.setFarSent(rec, nil)
        updateAlerts(force: true)
    }

    /// 60분 무하강 예약과 5km 이탈 알림. 위치를 받을 때 최대 1분에 한 번.
    private func updateAlerts(force: Bool = false, now: Date = .now) {
        guard let rec = recording, status == .recording else { return }
        guard force || now.timeIntervalSince(lastAlertCheck) >= 60 else { return }
        lastAlertCheck = now
        let summary = RunDetector.detect(points, vehicle: currentVehicle(now: now))
        let deadline = ForgottenStop.idleDeadline(rec, summary)
        switch ForgottenStop.idleAction(previous: ForgottenStop.idleDeadline(rec), new: deadline, now: now) {
        case .keep: break
        case .schedule: ForgottenStop.scheduleIdle(at: deadline, now: now)
        case .sendNow: ForgottenStop.scheduleIdle(at: nil, now: now, sendNow: true)
        case .cancel: ForgottenStop.scheduleIdle(at: nil, now: now)
        }
        ForgottenStop.setIdleDeadline(rec, deadline)
        // 리조트까지 거리는 알림에만 쓴다. 기록의 리조트 값은 바꾸지 않는다(R1). 정확도 나쁜 점·튀는 점은 쓰지 않는다.
        if let last = ForgottenStop.latestReliable(points), let resort = Resort.all.first(where: { $0.id == rec.resortId }),
           ForgottenStop.isFar(lat: last.lat, lon: last.lon, from: resort),
           ForgottenStop.farAlertAllowed(sentAt: ForgottenStop.farSentAt(rec), summary) {
            ForgottenStop.sendFar(resortName: resort.name)
            ForgottenStop.setFarSent(rec, now)
        }
    }

    /// 활동이 바뀔 때: 차량이 시작되면 표시하고, 끝나면 구간으로 저장한다. 알림 판단을 바로 다시 한다.
    func activityChanged(start: Date, automotive: Bool) {
        if automotive {
            if vehicleSince == nil { vehicleSince = start }
        } else if let since = vehicleSince {
            vehicleSince = nil
            addVehicle(DateInterval(start: since, end: max(since, start)))
        }
        updateAlerts(force: true)
    }

    private func addVehicle(_ interval: DateInterval) {
        guard let rec = recording else { return }
        vehicle.append(interval)
        // 저장 실패해도 기록은 계속한다. 끝난 뒤 활동 기록 조회로 다시 채운다.
        try? db.addVehicle(rec, interval)
    }

    /// 앱이 앞으로 올 때: 밤을 넘겨 살아 있던 앱도 영업일 끝을 지난 기록을 닫는다(위치가 오지 않아도). 그리고 차량 구간을 조회한다.
    func becameActive(now: Date = .now) {
        if let rec = recording, now >= BusinessDay.end(of: rec.startedAt) { closeAtDayEnd(rec) }
        // 설정에서 권한을 켜고 돌아왔으면 S3에서 고른 리조트로 시작
        if recording == nil {
            if pendingStart != nil { blocked = authProblem() }
            cancelIfDeniedNow()
            startPending()
        }
        // 8시간이 지났거나 꺼져 있던 카드를 다시 띄운다(앱이 앞에 있을 때만 된다)
        if recording != nil { showLive(renew: true) }
        refreshVehicles()
    }

    // MARK: Live Activity (R23)

    private func liveState(stopped: String? = nil) -> LiveRecording.State? {
        guard let rec = recording else { return nil }
        let t = today
        return .init(startedAt: rec.startedAt, runs: t.runs.count, distance: t.distance, stopped: stopped)
    }

    private func showLive(renew: Bool = false) {
        guard let rec = recording else { return }
        var stopped: String?
        if case .paused(let b) = status {
            stopped = switch b {
            case .denied: "위치 권한이 꺼졌어요. 앱을 열어 다시 켜 주세요"
            case .reducedAccuracy: "정확한 위치가 꺼졌어요. 앱을 열어 다시 켜 주세요"
            case .servicesOff: "위치 서비스가 꺼졌어요. 설정에서 다시 켜 주세요"
            }
        } else if case .failed = status {
            // 위치 수신이 끊겼거나 종료를 저장하지 못함: 기록은 멈춰 있다
            stopped = "기록이 멈췄어요. 앱을 열어 확인해 주세요"
        }
        if let s = liveState(stopped: stopped) { live.show(recordingId: rec.id, resortName: Resort.name(rec.resortId), s, renew: renew) }
    }

    /// 진행 중 기록과, 다시 조회할 끝난 기록의 차량 구간을 조회한다.
    func refreshVehicles() {
        if let rec = recording { refreshVehicle(rec) }
        for rec in (try? db.recordingsNeedingVehicle(now: .now)) ?? [] { refreshVehicle(rec) }
        refreshCaches()
    }

    /// 결과가 없거나 낡은 끝난 기록을 백그라운드에서 다시 계산한다 (R50, 리프트 대기 표본 포함).
    func refreshCaches() {
        let db = db
        Task.detached(priority: .utility) {
            var maps: [String: SlopeMap?] = [:]
            func map(_ id: String) -> SlopeMap? {
                if let m = maps[id] { return m }
                maps[id] = .some(SlopeMap.load(resortId: id))
                return maps[id]!
            }
            for rec in (try? db.recordingsNeedingCache(osmStamp: { AppDatabase.osmStamp(map($0)) })) ?? [] {
                try? db.refreshCache(rec, map: map(rec.resortId))
            }
        }
    }

    private func refreshVehicle(_ rec: Recording) {
        let queriedAt = Date.now
        Task { [weak self] in
            // 실패하면 기존 구간을 그대로 둔다
            guard let found = await ForgottenStop.queryVehicle(from: rec.startedAt, to: queriedAt),
                  let self, (try? self.db.setVehicle(rec, found, queriedAt: queriedAt)) == true else { return }
            if self.recording?.id == rec.id {
                self.vehicle = found
                self.updateAlerts(force: true)
            } else {
                self.refreshCaches()
            }
            self.loadToday()
        }
    }
}
