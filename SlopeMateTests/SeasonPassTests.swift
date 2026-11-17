import Foundation
import Testing
@testable import SlopeMate

struct SeasonPassTests {
    let f = ISO8601DateFormatter()
    func at(_ s: String) -> Date { f.date(from: s + "+09:00")! }
    func day(_ d: String, _ resort: String, runs: Int = 1) -> Stats.Day {
        let run = RunDetector.Run(start: at(d + "T10:00:00"), end: at(d + "T10:05:00"), distance: 1000, drop: 300, maxSpeed: 10, avgSpeed: 8, movingTime: 120)
        return Stats.Day(date: at(d + "T06:00:00"), resortId: resort, runs: Array(repeating: run, count: runs), usedGPSAltitude: false)
    }
    func pass(_ name: String, _ price: Int, order: Int, season: String = "2026-27") -> SeasonPass {
        SeasonPass(id: UUID(), season: season, name: name, price: price, sortOrder: order)
    }

    /// 여러 리조트 시즌권: 방문한 리조트 정가로 하루씩, 같은 날 두 곳이면 비싼 쪽 한 번
    @Test func multiResortTicketValue() {
        let x = pass("X", 599_000, order: 0)
        let days = [day("2026-12-05", "high1"), day("2026-12-06", "o2"), day("2026-12-12", "o2"), day("2026-12-12", "high1")]
        let r = PassValue.compute([(x, ["high1", "o2"])], days: days, season: "2026-27")
        #expect(r.perPass[x.id]! == PassValue.Value(visits: 3, price: 599_000))
        #expect(r.ticketValue[x.id] == 111_000 + 82_000 + 111_000)
    }

    @Test func perPassAndTotal() {
        let a = pass("A", 600_000, order: 0), b = pass("B", 400_000, order: 1)
        let days = [day("2026-12-05", "high1"), day("2026-12-06", "high1"), day("2026-12-06", "o2"), day("2026-12-12", "o2")]
        let r = PassValue.compute([(a, ["high1"]), (b, ["o2"])], days: days, season: "2026-27")
        #expect(r.perPass[a.id]! == PassValue.Value(visits: 2, price: 600_000))
        #expect(r.perPass[b.id]! == PassValue.Value(visits: 2, price: 400_000))
        #expect(r.ticketValue[a.id] == 222_000)   // 하이원 111,000 × 2
        #expect(r.ticketValue[b.id] == 164_000)   // 오투 82,000 × 2
        // 12/6은 두 리조트지만 전체로는 1일 → 3일
        #expect(r.total == PassValue.Value(visits: 3, price: 1_000_000))
    }

    @Test func overlappingResortCountsForUpperPassOnly() {
        let a = pass("A", 600_000, order: 1), b = pass("B", 400_000, order: 0)
        let r = PassValue.compute([(a, ["high1", "o2"]), (b, ["high1"])], days: [day("2026-12-05", "high1")], season: "2026-27")
        #expect(r.perPass[b.id]!?.visits == 1)
        #expect(r.perPass[a.id]! == nil) // 방문일 0 → 계산하지 않음
    }

    @Test func otherSeasonPassDoesNotTakeVisits() {
        let old = pass("작년", 500_000, order: 0, season: "2025-26"), now = pass("올해", 600_000, order: 1)
        let r = PassValue.compute([(old, ["high1"]), (now, ["high1"])], days: [day("2026-12-05", "high1")], season: "2026-27")
        #expect(r.perPass[now.id]!?.visits == 1)
        #expect(r.perPass[old.id] == nil)
        #expect(r.total == nil) // 이번 시즌 시즌권은 1장
    }

    @Test func dayWithoutRunsIsNotAVisit() {
        let a = pass("A", 600_000, order: 0)
        let r = PassValue.compute([(a, ["high1"])], days: [day("2026-12-05", "high1", runs: 0)], season: "2026-27")
        #expect(r.perPass[a.id]! == nil)
    }

    @Test func validation() {
        #expect(throws: PassValue.Invalid.emptyName) { try PassValue.validate(pass(" ", 1, order: 0), resorts: ["high1"]) }
        #expect(throws: PassValue.Invalid.nonPositivePrice) { try PassValue.validate(pass("A", 0, order: 0), resorts: ["high1"]) }
        #expect(throws: PassValue.Invalid.noResort) { try PassValue.validate(pass("A", 1, order: 0), resorts: []) }
    }

    @Test func saveLoadReorderDelete() throws {
        let db = try AppDatabase(path: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite").path)
        let a = pass("A", 600_000, order: 0), b = pass("B", 400_000, order: 1)
        try db.save(a, resorts: ["high1", "o2"])
        try db.save(b, resorts: ["vivaldi"])
        #expect(throws: PassValue.Invalid.noResort) { try db.save(pass("C", 1, order: 2), resorts: []) }
        try db.reorderPasses([b.id, a.id])
        let list = try db.passes(season: "2026-27")
        #expect(list.map(\.pass.name) == ["B", "A"])
        #expect(list[1].resorts == ["high1", "o2"])
        try db.save(a, resorts: ["high1"]) // 고치기: 대상 리조트 교체
        #expect(try db.passes(season: "2026-27")[1].resorts == ["high1"])
        try db.deletePass(b.id)
        #expect(try db.passes(season: "2026-27").map(\.pass.name) == ["A"])
    }

    @Test func homeResorts() throws {
        let db = try AppDatabase(path: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite").path)
        try db.setHomeResorts(["high1", "o2"])
        #expect(try db.homeResorts() == ["high1", "o2"])
        try db.setHomeResorts(["o2"])
        #expect(try db.homeResorts() == ["o2"])
        #expect(AppDatabase.defaultResort(homes: ["high1", "o2"], last: "o2") == "o2")
        #expect(AppDatabase.defaultResort(homes: ["high1", "o2"], last: "vivaldi") == "high1") // 한 번 고른 홈 밖 리조트는 기본값 아님
        #expect(AppDatabase.defaultResort(homes: [], last: "vivaldi") == "vivaldi")
        #expect(AppDatabase.defaultResort(homes: [], last: nil) == nil)
    }
}
