import Foundation
import GRDB

/// 시즌권 (R8, 03-requirements 5장). 금액은 원 단위 정수.
nonisolated struct SeasonPass: Codable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    var id: UUID
    var season: String           // "2026-27"
    var name: String
    var price: Int
    /// 쓰지 않음(2026-11-18부터 리조트별 정가 `PassValue.dayTicket`로 계산). 열 지우기는 마이그레이션이라 남겨 둠
    var dayTicketPrice: Int = 0
    var sortOrder: Int           // 작을수록 위. 리조트가 겹치면 위 시즌권에만 셈

    static let databaseTableName = "season_pass"
}

nonisolated struct PassResort: Codable, Hashable, FetchableRecord, PersistableRecord {
    var passId: UUID
    var resortId: String
    static let databaseTableName = "pass_resort"
}

nonisolated enum PassValue {
    struct Value: Equatable {
        var visits: Int
        var price: Int
        var perVisit: Double { Double(price) / Double(visits) }
    }
    struct Result: Equatable {
        /// 방문일 0인 시즌권은 nil(계산하지 않음)
        var perPass: [UUID: Value?]
        /// 리프트권으로 샀다면 쓴 금액, 시즌권별
        var ticketValue: [UUID: Int]
        /// 2장 이상일 때만
        var total: Value?
    }

    /// 리조트별 성인 하루 리프트권 주말 정가(가장 긴 주간권). 26/27 공식 값이 없는 곳은 25/26 값, 무주는 임시 80,000원.
    /// ponytail: 앱에 고정, 다음 업데이트에서 26/27 공식 값으로 고침(docs/todo.md)
    static let dayTicket: [String: Int] = [
        "high1": 111_000, "vivaldi": 99_000, "konjiam": 105_000, "alpensia": 76_000, "o2": 82_000, "phoenix": 99_000,
        "yongpyong": 96_000, "elysian": 100_000, "jisan": 97_000, "wellihilli": 80_000, "muju": 80_000, "edenvalley": 79_000,
    ]

    enum Invalid: Error, Equatable { case emptyName, nonPositivePrice, noResort }

    /// S10 저장 규칙: 이름, 양의 가격, 대상 리조트 1곳 이상.
    static func validate(_ pass: SeasonPass, resorts: [String]) throws {
        if pass.name.trimmingCharacters(in: .whitespaces).isEmpty { throw Invalid.emptyName }
        if pass.price <= 0 { throw Invalid.nonPositivePrice }
        if resorts.isEmpty { throw Invalid.noResort }
    }

    /// 같은 시즌의 시즌권끼리만, 하강이 있는 날(방문일)만 센다.
    static func compute(_ passes: [(pass: SeasonPass, resorts: [String])], days: [Stats.Day], season: String) -> Result {
        let mine = passes.filter { $0.pass.season == season }.sorted { $0.pass.sortOrder < $1.pass.sortOrder }
        // 리조트 → 맨 위 시즌권
        var owner: [String: UUID] = [:]
        for p in mine { for r in p.resorts where owner[r] == nil { owner[r] = p.pass.id } }
        let visits = Stats.days(days, inSeason: season).filter(\.isVisit)
        var perPass: [UUID: Value?] = [:], ticket: [UUID: Int] = [:]
        for p in mine {
            // 같은 날 두 리조트면 비싼 쪽 하루
            let byDate = Dictionary(grouping: visits.filter { owner[$0.resortId] == p.pass.id }, by: \.date)
            let n = byDate.count
            perPass[p.pass.id] = n > 0 ? Value(visits: n, price: p.pass.price) : nil
            ticket[p.pass.id] = byDate.values.reduce(0) { $0 + ($1.map { dayTicket[$0.resortId] ?? 0 }.max() ?? 0) }
        }
        var total: Value?
        if mine.count >= 2 {
            // 같은 날 두 리조트는 1일
            let n = Set(visits.filter { owner[$0.resortId] != nil }.map(\.date)).count
            if n > 0 { total = Value(visits: n, price: mine.reduce(0) { $0 + $1.pass.price }) }
        }
        return Result(perPass: perPass, ticketValue: ticket, total: total)
    }
}

extension AppDatabase {
    /// 시즌권과 대상 리조트를 한 트랜잭션으로 저장한다(새로 추가하거나 고침).
    /// 고칠 때 순서는 바꾸지 않는다. 순서는 reorderPasses로만 바꾼다.
    func save(_ pass: SeasonPass, resorts: [String]) throws {
        try PassValue.validate(pass, resorts: resorts)
        try queue.write { db in
            var pass = pass
            if let kept = try Int.fetchOne(db, sql: "SELECT sortOrder FROM season_pass WHERE id = ?", arguments: [pass.id]) {
                pass.sortOrder = kept
            }
            try pass.save(db)
            try PassResort.filter(Column("passId") == pass.id).deleteAll(db)
            for r in Set(resorts) { try PassResort(passId: pass.id, resortId: r).insert(db) }
        }
    }

    func deletePass(_ id: UUID) throws {
        try queue.write { db in
            try PassResort.filter(Column("passId") == id).deleteAll(db)
            _ = try SeasonPass.deleteOne(db, key: id)
        }
    }

    /// 순서 바꾸기: 주어진 순서대로 sortOrder를 다시 매긴다.
    func reorderPasses(_ ids: [UUID]) throws {
        try queue.write { db in
            for (i, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE season_pass SET sortOrder = ? WHERE id = ?", arguments: [i, id])
            }
        }
    }

    func passes(season: String) throws -> [(pass: SeasonPass, resorts: [String])] {
        try queue.read { db in
            try SeasonPass.filter(Column("season") == season).order(Column("sortOrder")).fetchAll(db).map { p in
                (p, try String.fetchAll(db, sql: "SELECT resortId FROM pass_resort WHERE passId = ? ORDER BY resortId", arguments: [p.id]))
            }
        }
    }
}
