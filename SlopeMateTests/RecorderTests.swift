import CoreLocation
import Foundation
import Testing
@testable import SlopeMate

/// 영업일 끝 안내가 UserDefaults 전역이라 순서대로 돈다.
@MainActor
@Suite(.serialized)
struct RecorderTests {
    let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite").path

    func unfinished(lastPointAgo: TimeInterval, now: Date) throws -> (AppDatabase, Recording) {
        let db = try AppDatabase(path: path)
        let rec = try db.createRecording(resortId: "high1", at: now - 3600)
        var p = Point(recordingId: rec.id, t: now - lastPointAgo, lat: 37, lon: 128, hAcc: 5, gpsAlt: 0, vAcc: 5, speed: 0, seq: 0)
        try db.insert(&p)
        return (db, rec)
    }

    /// 한국 시간 낮 12시 (영업일 경계에서 먼 시각)
    let noon = ISO8601DateFormatter().date(from: "2026-12-20T12:00:00+09:00")!

    @Test func shortInterruptionAutoResumes() throws {
        let (db, _) = try unfinished(lastPointAgo: 5 * 60, now: noon)
        let r = Recorder(db: db)
        r.handleLaunch(locationRelaunch: false, now: noon)
        #expect(r.pendingResume == nil)
        #expect(r.recording != nil)
        #expect(abs((r.autoResumedGap ?? 0) - 5 * 60) < 0.01) // DB 시각은 ms 단위
    }

    @Test func longInterruptionAsks() throws {
        let (db, _) = try unfinished(lastPointAgo: 30 * 60, now: noon)
        let r = Recorder(db: db)
        r.handleLaunch(locationRelaunch: false, now: noon)
        #expect(r.pendingResume != nil)
        #expect(r.recording == nil)
    }

    @Test func locationRelaunchAlwaysResumes() throws {
        let (db, _) = try unfinished(lastPointAgo: 30 * 60, now: noon)
        let r = Recorder(db: db)
        r.handleLaunch(locationRelaunch: true, now: noon)
        #expect(r.pendingResume == nil && r.recording != nil)
    }

    @Test func pausedByPermissionAsks() throws {
        let (db, rec) = try unfinished(lastPointAgo: 60, now: noon)
        try db.openGap(rec, reason: "permission", at: noon - 30)
        let r = Recorder(db: db)
        r.handleLaunch(locationRelaunch: false, now: noon)
        #expect(r.pendingResume != nil)
    }

    @Test func nextBusinessDayEnds() throws {
        let (db, rec) = try unfinished(lastPointAgo: 60, now: noon)
        let r = Recorder(db: db)
        r.handleLaunch(locationRelaunch: false, now: noon + 86400)
        #expect(r.pendingResume == nil && r.recording == nil)
        #expect(try db.unfinished() == nil)
        // R49: 마지막 위치점 시각으로, "기록 없음" 구간 없이 닫는다
        let f = try db.file(rec)
        #expect(f.recording.endReason == "dayEnd")
        #expect(abs(f.recording.endedAt!.timeIntervalSince(noon - 60)) < 0.01)
        #expect(f.gaps.isEmpty)
    }

    /// R49 실시간: 차량 이동이 시작되면 바로 판정에서 빼고, 끝나면 구간으로 저장한다.
    @Test func liveVehicleActivity() throws {
        let (db, rec) = try unfinished(lastPointAgo: 60, now: noon)
        let r = Recorder(db: db)
        r.recording = rec
        r.status = .recording
        r.activityChanged(start: noon - 600, automotive: true)
        #expect(r.vehicle.isEmpty) // 아직 이어지는 중
        r.activityChanged(start: noon - 300, automotive: true) // 차량이 이어짐: 시작은 그대로
        r.activityChanged(start: noon - 60, automotive: false)
        #expect(r.vehicle == [DateInterval(start: noon - 600, end: noon - 60)])
        #expect(try db.vehicle(rec).count == 1)
    }

    /// R49: 앱이 밤을 넘겨 살아 있고 위치가 오지 않아도(권한 꺼짐 등) 앞으로 오면 닫는다.
    @Test func becameActiveAfterDayEndCloses() throws {
        let (db, rec) = try unfinished(lastPointAgo: 60, now: noon)
        let r = Recorder(db: db)
        r.recording = rec
        r.status = .paused(.denied)
        r.becameActive(now: noon + 86400)
        #expect(r.recording == nil)
        let f = try db.file(rec)
        #expect(f.recording.endReason == "dayEnd" && abs(f.recording.endedAt!.timeIntervalSince(noon - 60)) < 0.01)
    }

    /// R49: 기록 중 영업일 끝(06:00)이 지난 첫 위치는 저장하지 않고 기록을 닫는다.
    @Test func firstPointAfterDayEndCloses() throws {
        let (db, rec) = try unfinished(lastPointAgo: 60, now: noon)
        let r = Recorder(db: db)
        r.recording = rec
        r.points = try db.points(rec)
        r.status = .recording
        let next6am = BusinessDay.end(of: rec.startedAt)
        r.save(CLLocation(coordinate: .init(latitude: 37, longitude: 128), altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: next6am + 1))
        #expect(r.recording == nil && r.status == .idle)
        let f = try db.file(rec)
        #expect(f.recording.endReason == "dayEnd" && f.points.count == 1)
    }

    /// 저장 실패로 끝난 표시도 못 남긴 기록은 자동으로 이어가지 않는다.
    @Test func storageFailedAsks() throws {
        let (db, rec) = try unfinished(lastPointAgo: 60, now: noon)
        UserDefaults.standard.set(rec.id.uuidString, forKey: Recorder.storageFailedKey)
        defer { UserDefaults.standard.removeObject(forKey: Recorder.storageFailedKey) }
        let r = Recorder(db: db)
        r.handleLaunch(locationRelaunch: true, now: noon)
        #expect(r.pendingResume != nil && r.recording == nil)
    }

    /// R4: 저장에 실패하면 조용히 계속하지 않고 기록을 멈춘다.
    @Test func saveFailureStopsRecording() throws {
        let (_, rec) = try unfinished(lastPointAgo: 60, now: .now)
        let r = Recorder(db: try AppDatabase(path: path, readonly: true))
        r.recording = rec
        r.status = .recording
        r.save(CLLocation(latitude: 37, longitude: 128))
        guard case .failed = r.status else { Issue.record("status \(r.status)"); return }
        #expect(r.recording == nil)
    }

    /// S7: 묻는 동안 06:00이 지났으면 "이어서"를 눌러도 이어가지 않고 영업일 끝으로 닫고 안내한다. 안내는 다시 실행해도 남고, 확인하면 지운다.
    @Test func answerResumeAfterDayEndCloses() throws {
        defer { UserDefaults.standard.removeObject(forKey: Recorder.dayEndKey) }
        let (db, rec) = try unfinished(lastPointAgo: 30 * 60, now: noon)
        let r = Recorder(db: db)
        r.handleLaunch(locationRelaunch: false, now: noon)
        #expect(r.pendingResume != nil)
        r.answerResume(true, now: BusinessDay.end(of: rec.startedAt) + 60)
        #expect(r.recording == nil && r.pendingResume == nil)
        #expect(try db.file(rec).recording.endReason == "dayEnd")
        #expect(r.dayEndNotice?.id == rec.id)
        // 다음 실행
        let r2 = Recorder(db: db)
        #expect(r2.dayEndNotice?.id == rec.id && r2.dayEndNotice?.endedAt != nil)
        r2.acknowledgeDayEnd()
        #expect(r2.dayEndNotice == nil && Recorder(db: db).dayEndNotice == nil)
    }

    /// S7 같은 영업일 "여기서 끝내기": 끊긴 기록으로 끝내고 영업일 끝 안내는 없다.
    @Test func answerResumeSameDayEnds() throws {
        UserDefaults.standard.removeObject(forKey: Recorder.dayEndKey)
        let (db, rec) = try unfinished(lastPointAgo: 30 * 60, now: noon)
        let r = Recorder(db: db)
        r.handleLaunch(locationRelaunch: false, now: noon)
        r.answerResume(false, now: noon + 60)
        #expect(try db.file(rec).recording.endReason == "interrupted")
        #expect(r.dayEndNotice == nil)
        let ended = try db.file(rec).recording
        #expect(db.day(of: ended)?.resortId == "high1")
    }

    /// S1: 고른 순서로 저장하고, 저장에 성공했을 때만 첫 실행 완료로 남긴다.
    @Test func homeSetupFlagOnlyAfterSave() throws {
        let before = Settings.homeSetupDone
        defer { Settings.homeSetupDone = before }
        let db = try AppDatabase(path: path)
        Settings.homeSetupDone = false
        #expect(throws: (any Error).self) { try Settings.saveHomeSetup(["o2"], db: try AppDatabase(path: path, readonly: true)) }
        #expect(!Settings.homeSetupDone)
        try Settings.saveHomeSetup(["o2", "high1"], db: db)
        #expect(Settings.homeSetupDone)
        #expect(try db.homeResorts() == ["o2", "high1"])
    }

    @Test func lastSavedText() {
        #expect(ResumeText.lastSaved(noon - 3600, now: noon) == "11:00")
        #expect(ResumeText.lastSaved(noon - 86400 + 3600, now: noon) == "어제 13:00")
        #expect(ResumeText.lastSaved(noon - 3 * 86400, now: noon) == "12월 17일 12:00")
    }

    /// S3 → 권한 없음: 시작하지 않고 고른 리조트를 들고 기다린다. 취소하면 대기를 버린다.
    /// 시뮬레이터에 위치 권한이 이미 있으면 바로 시작하므로 건너뛴다.
    @Test(.enabled(if: ![.authorizedAlways, .authorizedWhenInUse].contains(CLLocationManager().authorizationStatus)))
    func requestStartWaitsForPermissionThenCancels() throws {
        let r = Recorder(db: try AppDatabase(path: path))
        r.requestStart(resortId: "o2")
        #expect(r.recording == nil && r.pendingStart == "o2")
        r.becameActive()
        #expect(r.recording == nil && r.pendingStart == "o2")
        r.cancelPendingStart()
        #expect(r.pendingStart == nil)
    }
}
