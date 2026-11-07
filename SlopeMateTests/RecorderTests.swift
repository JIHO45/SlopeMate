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
        let (db, _) = try unfinished(lastPointAgo: 60, now: noon)
        let r = Recorder(db: db)
        r.handleLaunch(locationRelaunch: false, now: noon + 86400)
        #expect(r.pendingResume == nil && r.recording == nil)
        #expect(try db.unfinished() == nil)
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
