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

    // MARK: 마이그레이션 (R4: 앱 업데이트 후에도 기록이 남는다)

    func v2(fail: Bool) -> DatabaseMigrator {
        var m = AppDatabase.migrator
        m.registerMigration("v2") { db in
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
        _ = try AppDatabase(path: path, migrator: v2(fail: false))
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
        #expect(throws: (any Error).self) { try AppDatabase(path: path, migrator: v2(fail: true)) }
        let db = try AppDatabase(path: path)
        #expect(try db.queue.read { try Point.fetchCount($0) } == 1)
        #expect(try db.queue.read { try AppDatabase.migrator.appliedIdentifiers($0) } == ["v1"])
    }

    @Test func backupFailureBlocksMigration() throws {
        _ = try AppDatabase(path: path)
        // 백업 경로 자리에 폴더를 만들어 백업을 실패시킨다
        try FileManager.default.createDirectory(atPath: path + ".premigration/x", withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try AppDatabase(path: path, migrator: v2(fail: false)) }
        let q = try DatabaseQueue(path: path)
        #expect(try q.read { try v2(fail: false).appliedIdentifiers($0) } == ["v1"])
    }
}
