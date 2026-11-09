import Foundation
import GRDB
import Testing
@testable import SlopeMate

struct DatabaseTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var path: String { dir.appending(path: "t.sqlite").path }

    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    func point(_ rec: Recording, _ t: Date, seq: Int = 0) -> Point {
        Point(recordingId: rec.id, t: t, lat: 37, lon: 128, hAcc: 5, gpsAlt: 0, vAcc: 5, speed: 0, seq: seq)
    }

    @Test func pragmas() throws {
        let db = try AppDatabase(path: path)
        let (mode, sync) = try db.queue.read { db in
            (try String.fetchOne(db, sql: "PRAGMA journal_mode"), try Int.fetchOne(db, sql: "PRAGMA synchronous"))
        }
        #expect(mode == "wal")
        #expect(sync == 2) // FULL
    }

    @Test func businessDay() throws {
        let f = ISO8601DateFormatter()
        let before = f.date(from: "2026-11-08T05:59:00+09:00")!
        let at6 = f.date(from: "2026-11-08T06:00:00+09:00")!
        let lateNight = f.date(from: "2026-11-09T01:30:00+09:00")!
        #expect(!BusinessDay.same(before, at6))
        #expect(BusinessDay.same(at6, lateNight)) // 자정 넘은 심야는 전날 영업일
        #expect(BusinessDay.end(of: at6) == f.date(from: "2026-11-09T06:00:00+09:00")!)
    }

    @Test func restartOpensGapAndFirstPointClosesIt() throws {
        let db = try AppDatabase(path: path)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let rec = try db.createRecording(resortId: "high1", at: t0)
        var p = point(rec, t0 + 10)
        try db.insert(&p)
        let seq = try db.restart(rec, reason: "system", at: t0 + 600)
        #expect(seq == 1)
        var gaps = try db.file(rec).gaps
        #expect(gaps.count == 1 && gaps[0].fromT == t0 + 10 && gaps[0].toT == nil && gaps[0].reason == "system")
        var q = point(rec, t0 + 620, seq: 1)
        try db.insert(&q)
        gaps = try db.file(rec).gaps
        #expect(gaps[0].toT == t0 + 620)
    }

    @Test func permissionGapNotDuplicatedByRestart() throws {
        let db = try AppDatabase(path: path)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let rec = try db.createRecording(resortId: "high1", at: t0)
        try db.openGap(rec, reason: "permission", at: t0 + 5)
        _ = try db.restart(rec, reason: "permission", at: t0 + 60)
        #expect(try db.file(rec).gaps.count == 1)
    }

    /// 첫 위치점 전에 끊겼다 재개: 공백은 기록 시작부터. 첫 점 전에 권한이 꺼지면 이유가 권한으로 바뀐다.
    @Test func gapBeforeFirstPoint() throws {
        let db = try AppDatabase(path: path)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let rec = try db.createRecording(resortId: "high1", at: t0)
        _ = try db.restart(rec, reason: "auto", at: t0 + 300)
        try db.openGap(rec, reason: "permission", at: t0 + 310)
        let gaps = try db.file(rec).gaps
        #expect(gaps.count == 1 && gaps[0].fromT == t0 && gaps[0].reason == "permission")
    }

    /// 위치점 없이 끊긴 기록: 시작 ~ min(지금, 영업일 끝)이 "기록 없음"이 되고 그 시각에 끝난다.
    @Test func interruptedWithoutPoints() throws {
        let db = try AppDatabase(path: path)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let rec = try db.createRecording(resortId: "high1", at: t0)
        let now = t0 + 3 * 86400
        try db.endInterrupted(rec, now: now)
        let f = try db.file(rec)
        let end = BusinessDay.end(of: t0)
        #expect(f.recording.endedAt == end && f.recording.endReason == "interrupted")
        #expect(f.gaps.count == 1 && f.gaps[0].fromT == t0 && f.gaps[0].toT == end)
        #expect(try db.unfinished() == nil)
    }

    // MARK: R49

    @Test func endAtLastPoint() throws {
        let db = try AppDatabase(path: path)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let rec = try db.createRecording(resortId: "high1", at: t0)
        var p = point(rec, t0 + 600)
        try db.insert(&p)
        try db.endAtLastPoint(rec, reason: "dayEnd")
        let f = try db.file(rec)
        #expect(abs(f.recording.endedAt!.timeIntervalSince(t0 + 600)) < 0.01 && f.recording.endReason == "dayEnd")
        // 위치점이 없으면 시작 시각
        let empty = try db.createRecording(resortId: "high1", at: t0)
        try db.endAtLastPoint(empty, reason: "dayEnd")
        #expect(abs(try db.file(empty).recording.endedAt!.timeIntervalSince(t0)) < 0.01)
    }

    @Test func vehicleNewerQueryWins() throws {
        let db = try AppDatabase(path: path)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let rec = try db.createRecording(resortId: "high1", at: t0)
        let a = [DateInterval(start: t0 + 10, end: t0 + 20)], b = [DateInterval(start: t0 + 30, end: t0 + 40)]
        #expect(try db.setVehicle(rec, b, queriedAt: t0 + 200))
        #expect(try !db.setVehicle(rec, a, queriedAt: t0 + 100)) // 늦게 끝난 옛 조회는 덮어쓰지 않음
        #expect(try db.vehicle(rec) == b)
        #expect(try db.setVehicle(rec, [], queriedAt: t0 + 300))  // 성공한 빈 결과는 지운다
        #expect(try db.vehicle(rec).isEmpty)
    }

    @Test func recordingsNeedingVehicle() throws {
        let db = try AppDatabase(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = try db.createRecording(resortId: "high1", at: now - 7200)
        try db.end(recent, at: now - 3600, reason: "user")
        try db.setVehicle(recent, [], queriedAt: now - 3600) // 끝나자마자 조회 → 다시 조회 대상
        let done = try db.createRecording(resortId: "high1", at: now - 7200)
        try db.end(done, at: now - 3600, reason: "user")
        try db.setVehicle(done, [], queriedAt: now - 600)   // 15분 지나 조회함
        let old = try db.createRecording(resortId: "high1", at: now - 7 * 86400)
        try db.end(old, at: now - 7 * 86400 + 3600, reason: "user")
        #expect(try db.recordingsNeedingVehicle(now: now).map(\.id) == [recent.id])
    }

    @Test func oldFileWithoutVehicleDecodes() throws {
        let rec = Recording(id: UUID(), resortId: "high1", startedAt: Date(timeIntervalSince1970: 0))
        var json = try JSONSerialization.jsonObject(with: RecordingFile.encoder.encode(RecordingFile(recording: rec, points: [], restarts: [], gaps: []))) as! [String: Any]
        json["vehicle"] = nil
        let f = try RecordingFile.decoder.decode(RecordingFile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(f.vehicle.isEmpty)
    }

    /// v1만 있던 DB를 최신까지 올려도 위치점이 남는다.
    @Test func upgradeFromV1KeepsPoints() throws {
        do {
            let db = try AppDatabase(path: path)
            let rec = try db.createRecording(resortId: "high1", at: Date())
            var p = point(rec, Date())
            try db.insert(&p)
            try db.queue.write { db in
                for t in ["lift_wait", "vehicle", "pass_resort", "season_pass", "home_resort"] { try db.execute(sql: "DROP TABLE \(t)") }
                try db.execute(sql: "ALTER TABLE recording DROP COLUMN vehicleQueriedAt")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier != 'v1'")
            }
        }
        let db = try AppDatabase(path: path)
        #expect(try db.queue.read { try Point.fetchCount($0) } == 1)
        #expect(try db.queue.read { try AppDatabase.migrator.appliedIdentifiers($0) } == Set(AppDatabase.migrator.migrations))
    }

    // MARK: 마이그레이션 (R4: 앱 업데이트 후에도 기록이 남는다)

    func next(fail: Bool) -> DatabaseMigrator {
        var m = AppDatabase.migrator
        m.registerMigration("test-next") { db in
            try db.alter(table: "recording") { $0.add(column: "note", .text) }
            if fail { throw DatabaseError(message: "boom") }
        }
        return m
    }

    @Test func backupBeforeMigrationIncludesWAL() throws {
        let rec: Recording
        do {
            let db = try AppDatabase(path: path)
            rec = try db.createRecording(resortId: "high1", at: Date())
            var p = point(rec, Date())
            try db.insert(&p) // 체크포인트 전이라 WAL에만 있음
        }
        _ = try AppDatabase(path: path, migrator: next(fail: false))
        let backup = try DatabaseQueue(path: path + ".premigration")
        #expect(try backup.read { try Point.fetchCount($0) } == 1)
    }

    @Test func failedMigrationKeepsData() throws {
        do {
            let db = try AppDatabase(path: path)
            let rec = try db.createRecording(resortId: "high1", at: Date())
            var p = point(rec, Date())
            try db.insert(&p)
        }
        #expect(throws: (any Error).self) { try AppDatabase(path: path, migrator: next(fail: true)) }
        let db = try AppDatabase(path: path)
        #expect(try db.queue.read { try Point.fetchCount($0) } == 1)
        #expect(try db.queue.read { try AppDatabase.migrator.appliedIdentifiers($0) } == Set(AppDatabase.migrator.migrations))
    }

    @Test func backupFailureBlocksMigration() throws {
        _ = try AppDatabase(path: path)
        // 백업 경로 자리에 폴더를 만들어 백업을 실패시킨다
        try FileManager.default.createDirectory(atPath: path + ".premigration/x", withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try AppDatabase(path: path, migrator: next(fail: false)) }
        let q = try DatabaseQueue(path: path)
        #expect(try q.read { try next(fail: false).appliedIdentifiers($0) } == Set(AppDatabase.migrator.migrations))
    }
}
