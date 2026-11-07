import Foundation
import GRDB

// 05-design 4장 기기 안 데이터. 하강은 저장하지 않고 위치점에서 계산한다(RunDetector).

nonisolated struct Recording: Codable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    var id: UUID
    var resortId: String
    var startedAt: Date
    var endedAt: Date?
    /// user, interrupted(끊긴 뒤 이어서 기록 안 함), storage(저장 실패)
    var endReason: String?
}

nonisolated struct Point: Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var recordingId: UUID
    var t: Date
    var lat: Double
    var lon: Double
    var hAcc: Double
    var gpsAlt: Double
    var vAcc: Double
    var speed: Double
    /// 기압 상대고도(m). 같은 seq 안에서만 기준이 같다.
    var baroAlt: Double?
    var baroT: Date?
    var seq: Int

    static let databaseTableName = "point"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

nonisolated struct Restart: Codable, Hashable, FetchableRecord, PersistableRecord {
    var recordingId: UUID
    var seq: Int
    var at: Date
    /// start, system, user, permission
    var reason: String
}

/// "기록 없음" 구간. toT가 nil이면 아직 첫 위치점을 기다리는 중.
nonisolated struct Gap: Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var recordingId: UUID
    var fromT: Date
    var toT: Date?
    var reason: String

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// 기록 1건 전체. R22 내보내기 파일과 재생 테스트 파일의 형식.
nonisolated struct RecordingFile: Codable {
    var recording: Recording
    var points: [Point]
    var restarts: [Restart]
    var gaps: [Gap]

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// 영업일: 한국 시간 06:00 ~ 다음 날 06:00 (03-requirements 5장).
nonisolated enum BusinessDay {
    static func start(of t: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return cal.startOfDay(for: t.addingTimeInterval(-6 * 3600)).addingTimeInterval(6 * 3600)
    }
    static func end(of t: Date) -> Date { start(of: t).addingTimeInterval(24 * 3600) } // 한국은 서머타임 없음
    static func same(_ a: Date, _ b: Date) -> Bool { start(of: a) == start(of: b) }
}

nonisolated final class AppDatabase: Sendable {
    let queue: DatabaseQueue

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "recording") { t in
                t.primaryKey("id", .blob)
                t.column("resortId", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("endReason", .text)
            }
            try db.create(table: "point") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("recordingId", .blob).notNull().indexed().references("recording")
                t.column("t", .datetime).notNull()
                for c in ["lat", "lon", "hAcc", "gpsAlt", "vAcc", "speed"] { t.column(c, .double).notNull() }
                t.column("baroAlt", .double)
                t.column("baroT", .datetime)
                t.column("seq", .integer).notNull()
            }
            try db.create(table: "restart") { t in
                t.column("recordingId", .blob).notNull().references("recording")
                t.column("seq", .integer).notNull()
                t.column("at", .datetime).notNull()
                t.column("reason", .text).notNull()
                t.primaryKey(["recordingId", "seq"])
            }
            try db.create(table: "gap") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("recordingId", .blob).notNull().indexed().references("recording")
                t.column("fromT", .datetime).notNull()
                t.column("toT", .datetime)
                t.column("reason", .text).notNull()
            }
        }
        return m
    }

    static func defaultPath() throws -> String {
        let dir = URL.applicationSupportDirectory.appending(path: "SlopeMate")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 화면이 잠긴 동안에도 쓸 수 있게. 폴더 안에 새로 생기는 -wal·-shm도 이 등급을 물려받는다.
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
        return dir.appending(path: "slopemate.sqlite").path
    }

    /// 이미 적용된 마이그레이션이 있고 새 마이그레이션이 남아 있으면, 먼저 `<path>.premigration`에 일관된 백업을 만든다.
    /// 백업이 실패하면 마이그레이션하지 않고 오류를 던진다. 마이그레이션이 실패하면 GRDB가 되돌리고 오류를 던진다.
    init(path: String, migrator: DatabaseMigrator = AppDatabase.migrator, readonly: Bool = false) throws {
        var config = Configuration()
        config.readonly = readonly
        config.prepareDatabase { db in
            if !db.configuration.readonly { try db.execute(sql: "PRAGMA journal_mode = WAL") }
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        queue = try DatabaseQueue(path: path, configuration: config)
        if readonly { return }

        let (applied, done) = try queue.read { (try migrator.appliedIdentifiers($0), try migrator.hasCompletedMigrations($0)) }
        if !applied.isEmpty && !done {
            try queue.backup(to: DatabaseQueue(path: path + ".premigration")) // 이전 백업은 덮어씀
        }
        try migrator.migrate(queue)
    }

    // MARK: 쓰기

    func createRecording(resortId: String, at: Date) throws -> Recording {
        let rec = Recording(id: UUID(), resortId: resortId, startedAt: at)
        try queue.write { db in
            try rec.insert(db)
            try Restart(recordingId: rec.id, seq: 0, at: at, reason: "start").insert(db)
        }
        return rec
    }

    /// 위치점 1개 = 트랜잭션 1개. 열린 "기록 없음" 구간은 첫 위치점 시각에서 닫는다.
    func insert(_ p: inout Point) throws {
        try queue.write { db in
            try p.insert(db)
            try db.execute(sql: "UPDATE gap SET toT = ? WHERE recordingId = ? AND toT IS NULL", arguments: [p.t, p.recordingId])
        }
    }

    /// 새 seq를 만들고, 열린 공백이 없으면 마지막 위치점부터 공백을 연다. 한 트랜잭션.
    func restart(_ rec: Recording, reason: String, at: Date) throws -> Int {
        try queue.write { db in
            let seq = (try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM restart WHERE recordingId = ?", arguments: [rec.id]) ?? -1) + 1
            try Restart(recordingId: rec.id, seq: seq, at: at, reason: reason).insert(db)
            try Self.openGap(db, rec, reason: reason, at: at)
            return seq
        }
    }

    func openGap(_ rec: Recording, reason: String, at: Date) throws {
        try queue.write { try Self.openGap($0, rec, reason: reason, at: at) }
    }

    private static func openGap(_ db: Database, _ rec: Recording, reason: String, at: Date) throws {
        let open = try Gap.filter(Column("recordingId") == rec.id && Column("toT") == nil).fetchCount(db)
        guard open == 0 else {
            // 재시작 후 첫 점을 기다리던 중 권한이 꺼지면, 다음 실행에서 S7로 묻도록 이유를 권한으로 바꾼다
            if reason == "permission" {
                try db.execute(sql: "UPDATE gap SET reason = 'permission' WHERE recordingId = ? AND toT IS NULL", arguments: [rec.id])
            }
            return
        }
        let last = try Date.fetchOne(db, sql: "SELECT MAX(t) FROM point WHERE recordingId = ?", arguments: [rec.id])
        var gap = Gap(recordingId: rec.id, fromT: last ?? rec.startedAt, reason: reason)
        try gap.insert(db)
    }

    /// 정상 종료. 아직 열린 공백은 종료 시각에서 닫는다.
    func end(_ rec: Recording, at: Date, reason: String) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE gap SET toT = ? WHERE recordingId = ? AND toT IS NULL", arguments: [at, rec.id])
            try db.execute(sql: "UPDATE recording SET endedAt = ?, endReason = ? WHERE id = ?", arguments: [at, reason, rec.id])
        }
    }

    /// 이어서 기록하지 않는 끊긴 기록: 마지막 위치점부터 min(지금, 영업일 끝)까지를 "기록 없음"으로 남기고 끝낸다.
    func endInterrupted(_ rec: Recording, now: Date) throws {
        try queue.write { db in
            let last = try Date.fetchOne(db, sql: "SELECT MAX(t) FROM point WHERE recordingId = ?", arguments: [rec.id]) ?? rec.startedAt
            let end = max(last, min(now, BusinessDay.end(of: rec.startedAt)))
            try Self.openGap(db, rec, reason: "interrupted", at: last)
            try db.execute(sql: "UPDATE gap SET toT = ? WHERE recordingId = ? AND toT IS NULL", arguments: [end, rec.id])
            try db.execute(sql: "UPDATE recording SET endedAt = ?, endReason = 'interrupted' WHERE id = ?", arguments: [end, rec.id])
        }
    }

    // MARK: 읽기

    func unfinished() throws -> Recording? {
        try queue.read { try Recording.filter(Column("endedAt") == nil).order(Column("startedAt").desc).fetchOne($0) }
    }

    func recordings(since: Date) throws -> [Recording] {
        try queue.read { try Recording.filter(Column("startedAt") >= since).order(Column("startedAt")).fetchAll($0) }
    }

    func points(_ rec: Recording) throws -> [Point] {
        try queue.read { try Point.filter(Column("recordingId") == rec.id).order(Column("t")).fetchAll($0) }
    }

    func file(_ rec: Recording) throws -> RecordingFile {
        try queue.read { db in
            let byRec = Column("recordingId") == rec.id
            return RecordingFile(
                recording: try Recording.fetchOne(db, key: rec.id) ?? rec,
                points: try Point.filter(byRec).order(Column("t")).fetchAll(db),
                restarts: try Restart.filter(byRec).order(Column("seq")).fetchAll(db),
                gaps: try Gap.filter(byRec).order(Column("fromT")).fetchAll(db))
        }
    }
}
