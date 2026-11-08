import CoreLocation
import Foundation
import Testing
@testable import SlopeMate

@MainActor
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
}
