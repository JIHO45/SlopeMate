import Foundation
import GRDB

// 05-design 4장 기기 안 데이터. 하강은 저장하지 않고 위치점에서 계산한다(RunDetector).

nonisolated struct Recording: Codable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    var id: UUID
    var resortId: String
    var startedAt: Date
    var endedAt: Date?
    /// user, interrupted(끊긴 뒤 이어서 기록 안 함), storage(저장 실패), dayEnd(영업일 끝에 닫음, R49)
    var endReason: String?
    /// 차량 구간을 마지막으로 성공적으로 조회한 시각 (R49)
    var vehicleQueriedAt: Date?
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

/// 동작 센서가 차량 이동으로 판단한 구간. 하강·거리에서 뺀다(R49).
nonisolated struct VehicleInterval: Codable, Hashable, FetchableRecord, PersistableRecord {
    var recordingId: UUID
    var fromT: Date
    var toT: Date

    static let databaseTableName = "vehicle"
    var interval: DateInterval { DateInterval(start: fromT, end: max(fromT, toT)) }
}

/// 기록 1건 전체. R22 내보내기 파일과 재생 테스트 파일의 형식.
nonisolated struct RecordingFile: Codable {
    var recording: Recording
    var points: [Point]
    var restarts: [Restart]
    var gaps: [Gap]
    var vehicle: [VehicleInterval] = []

    init(recording: Recording, points: [Point], restarts: [Restart], gaps: [Gap], vehicle: [VehicleInterval] = []) {
        (self.recording, self.points, self.restarts, self.gaps, self.vehicle) = (recording, points, restarts, gaps, vehicle)
    }

    /// vehicle이 없는 이전 파일도 읽는다
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recording = try c.decode(Recording.self, forKey: .recording)
        points = try c.decode([Point].self, forKey: .points)
        restarts = try c.decode([Restart].self, forKey: .restarts)
        gaps = try c.decode([Gap].self, forKey: .gaps)
        vehicle = try c.decodeIfPresent([VehicleInterval].self, forKey: .vehicle) ?? []
    }

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
        m.registerMigration("v2") { db in
            try db.alter(table: "recording") { $0.add(column: "vehicleQueriedAt", .datetime) }
            try db.create(table: "vehicle") { t in
                t.column("recordingId", .blob).notNull().indexed().references("recording")
                t.column("fromT", .datetime).notNull()
                t.column("toT", .datetime).notNull()
            }
        }
        m.registerMigration("v3") { db in
            try db.create(table: "season_pass") { t in
                t.primaryKey("id", .blob)
                t.column("season", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("price", .integer).notNull()
                t.column("dayTicketPrice", .integer).notNull()
                t.column("sortOrder", .integer).notNull()
            }
            try db.create(table: "pass_resort") { t in
                t.column("passId", .blob).notNull().references("season_pass", onDelete: .cascade)
                t.column("resortId", .text).notNull()
                t.primaryKey(["passId", "resortId"])
            }
        }
        m.registerMigration("v4") { db in
            try db.create(table: "home_resort") { t in
                t.primaryKey("resortId", .text)
                t.column("sortOrder", .integer).notNull()
            }
        }
        m.registerMigration("v5") { db in
            try db.create(table: "lift_wait") { t in
                t.column("recordingId", .blob).notNull().references("recording", onDelete: .cascade)
                t.column("boardAt", .datetime).notNull()
                t.column("resortId", .text).notNull()
                t.column("liftId", .text).notNull()
                t.column("waitSec", .double).notNull()
                t.column("sendState", .text).notNull().indexed()
                t.primaryKey(["recordingId", "boardAt"])
            }
        }
        m.registerMigration("v6") { db in
            try db.create(table: "snow_rating") { t in
                t.column("recordingId", .blob).notNull().references("recording", onDelete: .cascade)
                t.column("runStart", .datetime).notNull()
                t.column("runEnd", .datetime).notNull()
                t.column("resortId", .text).notNull()
                t.column("slopeId", .text).notNull()
                t.column("value", .text).notNull()
                t.column("ratedAt", .datetime).notNull()
                t.column("sendState", .text).notNull().indexed()
                t.primaryKey(["recordingId", "runStart"])
            }
        }
        m.registerMigration("v7") { db in
            try db.create(table: "recording_cache") { t in
                t.primaryKey("recordingId", .blob).references("recording", onDelete: .cascade)
                t.column("version", .integer).notNull()
                t.column("vehicleQueriedAt", .datetime)
                t.column("osmTimestamp", .text).notNull()
                t.column("data", .blob).notNull()
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

    /// 종료를 잊은 기록(R49): 마지막 위치점 시각으로 끝낸다. 위치점이 없으면 시작 시각.
    func endAtLastPoint(_ rec: Recording, reason: String) throws {
        try queue.write { db in
            let last = try Date.fetchOne(db, sql: "SELECT MAX(t) FROM point WHERE recordingId = ?", arguments: [rec.id]) ?? rec.startedAt
            try db.execute(sql: "UPDATE gap SET toT = ? WHERE recordingId = ? AND toT IS NULL", arguments: [last, rec.id])
            try db.execute(sql: "UPDATE recording SET endedAt = ?, endReason = ? WHERE id = ?", arguments: [last, reason, rec.id])
        }
    }

    /// 기록 중 실시간으로 받은 차량 구간 하나를 더한다. 조회 시각은 바꾸지 않는다(끝난 뒤 조회가 전체를 다시 채움).
    func addVehicle(_ rec: Recording, _ interval: DateInterval) throws {
        try queue.write { try VehicleInterval(recordingId: rec.id, fromT: interval.start, toT: interval.end).insert($0) }
    }

    /// 차량 구간을 바꾼다. 더 최근에 시작한 조회가 이미 저장됐으면 쓰지 않고 false.
    @discardableResult
    func setVehicle(_ rec: Recording, _ intervals: [DateInterval], queriedAt: Date) throws -> Bool {
        try queue.write { db in
            let stored = try Date.fetchOne(db, sql: "SELECT vehicleQueriedAt FROM recording WHERE id = ?", arguments: [rec.id])
            if let stored, stored >= queriedAt { return false }
            try VehicleInterval.filter(Column("recordingId") == rec.id).deleteAll(db)
            for i in intervals { try VehicleInterval(recordingId: rec.id, fromT: i.start, toT: i.end).insert(db) }
            try db.execute(sql: "UPDATE recording SET vehicleQueriedAt = ? WHERE id = ?", arguments: [queriedAt, rec.id])
            return true
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

    // MARK: 홈 리조트 (R1)

    func homeResorts() throws -> [String] {
        try queue.read { try String.fetchAll($0, sql: "SELECT resortId FROM home_resort ORDER BY sortOrder") }
    }

    func setHomeResorts(_ ids: [String]) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM home_resort")
            for (i, id) in ids.enumerated() {
                try db.execute(sql: "INSERT OR IGNORE INTO home_resort (resortId, sortOrder) VALUES (?, ?)", arguments: [id, i])
            }
        }
    }

    /// 기록 시작 기본 리조트: 마지막으로 기록한 리조트가 홈 리조트면 그것, 아니면 첫 홈 리조트.
    /// 홈에 없는 리조트로 한 번 기록한 것은 기본값이 되지 않는다(R1 "이번 기록에만").
    nonisolated static func defaultResort(homes: [String], last: String?) -> String? {
        if let last, homes.contains(last) { return last }
        return homes.first ?? last
    }

    // MARK: 읽기

    func unfinished() throws -> Recording? {
        try queue.read { try Recording.filter(Column("endedAt") == nil).order(Column("startedAt").desc).fetchOne($0) }
    }

    func recordings(since: Date) throws -> [Recording] {
        try queue.read { try Recording.filter(Column("startedAt") >= since).order(Column("startedAt")).fetchAll($0) }
    }

    func vehicle(_ rec: Recording) throws -> [DateInterval] {
        try queue.read { try VehicleInterval.filter(Column("recordingId") == rec.id).order(Column("fromT")).fetchAll($0).map(\.interval) }
    }

    /// 차량 구간을 다시 조회할 끝난 기록: 시작이 6일 이내(활동 기록 보관 7일 안에서 전체 범위 조회 가능)이고,
    /// 끝난 뒤 15분이 지나 조회한 적이 없음(활동 기록이 늦게 들어올 수 있음).
    func recordingsNeedingVehicle(now: Date) throws -> [Recording] {
        try queue.read { db in
            try Recording.fetchAll(db, sql: """
                SELECT * FROM recording WHERE endedAt IS NOT NULL AND startedAt >= ?
                AND (vehicleQueriedAt IS NULL OR vehicleQueriedAt < datetime(endedAt, '+15 minutes'))
                """, arguments: [now.addingTimeInterval(-6 * 86400)])
        }
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
                gaps: try Gap.filter(byRec).order(Column("fromT")).fetchAll(db),
                vehicle: try VehicleInterval.filter(byRec).order(Column("fromT")).fetchAll(db))
        }
    }
}
