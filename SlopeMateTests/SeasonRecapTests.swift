import Foundation
import Testing
@testable import SlopeMate

struct SeasonRecapTests {
    let f = ISO8601DateFormatter()
    func at(_ s: String) -> Date { f.date(from: s + "+09:00")! }
    func run(_ t: String, slope: String? = nil) -> RunDetector.Run {
        RunDetector.Run(start: at(t), end: at(t) + 120, distance: 1500, drop: 320, maxSpeed: 12, avgSpeed: 10, movingTime: 120, slopeId: slope)
    }
    func day(_ d: String, _ resort: String, _ runs: [RunDetector.Run]) -> Stats.Day {
        Stats.Day(date: at(d + "T06:00:00"), resortId: resort, runs: runs, usedGPSAltitude: false)
    }
    var days: [Stats.Day] {
        [day("2026-12-05", "high1", [run("2026-12-05T10:00:00", slope: "a"), run("2026-12-05T19:00:00", slope: "a"), run("2026-12-05T23:30:00")]),
         day("2026-12-06", "high1", [run("2026-12-06T10:00:00", slope: "b")]),
         day("2026-12-06", "o2", [run("2026-12-06T15:00:00")]),
         day("2026-03-01", "high1", [run("2026-03-01T10:00:00")])]  // 지난 시즌
    }
    /// 10시 주간, 19시 야간, 23시 이후 심야
    func session(_ r: RunDetector.Run, _: String) -> SessionKind? {
        let h = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "Asia/Seoul")!, from: r.start).hour!
        return h >= 23 ? .lateNight : h >= 18 ? .night : .day
    }

    @Test func matchesSeasonTotalsAndOrder() {
        let cards = SeasonRecap.cards(days: days, season: "2026-27", session: session, slopeName: { _, id in id == "a" ? "제우스 2" : nil })
        let t = Stats.totals(Stats.days(days, inSeason: "2026-27"))
        #expect(cards.first == .totals(visitDays: t.visitDays, runs: t.runs, distance: t.distance))
        #expect(t.visitDays == 2 && t.runs == 5)
        #expect(cards[1] == .drop(total: t.drop, perDay: t.drop / 2))
        guard case let .sessions(s) = cards[2] else { Issue.record("세션 카드 없음"); return }
        #expect(s.map(\.percent).reduce(0, +) == 100)
        #expect(s.map(\.runs) == [3, 1, 1])
        #expect(cards[3] == .topResort(resortId: "high1", days: 2, of: 2, runs: 4, distance: 6000))
        #expect(cards[4] == .topDay(date: at("2026-12-05T06:00:00"), resortId: "high1", runs: 3, distance: 4500, drop: 960))
        #expect(cards[5] == .topSlope(name: "제우스 2", resortId: "high1", runs: 2))
        #expect(cards.count == 6)  // 시즌권 없음 → 본전 카드 없음
    }

    @Test func percentsSumTo100WithThirds() {
        let d = [day("2026-12-05", "high1", [run("2026-12-05T10:00:00"), run("2026-12-05T19:00:00"), run("2026-12-05T23:30:00")])]
        guard case let .sessions(s) = SeasonRecap.cards(days: d, season: "2026-27", session: session)[2] else { Issue.record(); return }
        #expect(s.map(\.percent).reduce(0, +) == 100)
    }

    @Test func slopeNamesOffOrNoTimetableDropsCards() {
        let cards = SeasonRecap.cards(days: days, season: "2026-27")
        #expect(!cards.contains { if case .topSlope = $0 { true } else { false } })
        #expect(!cards.contains { if case .sessions = $0 { true } else { false } })
        #expect(SeasonRecap.cards(days: days, season: "2027-28").isEmpty)
    }

    @Test func passCardOnlyWhenRegistered() {
        let p = SeasonPass(id: UUID(), season: "2026-27", name: "하이원 시즌권", price: 600_000, sortOrder: 0)
        let cards = SeasonRecap.cards(days: days, season: "2026-27", passes: [(p, ["high1"])])
        #expect(cards.last == .pass(name: "하이원 시즌권", visits: 2, perVisit: 300_000, ticket: 222_000))
    }

    @Test func finalAfterApril30() {
        #expect(!SeasonRecap.isFinal(season: "2026-27", now: at("2027-04-30T23:59:00")))
        #expect(SeasonRecap.isFinal(season: "2026-27", now: at("2027-05-01T00:00:00")))
        #expect(!SeasonRecap.isFinal(season: "2026-27", now: at("2026-11-14T12:00:00")))
    }

    @Test func lockBySeasonOfRecord() {
        #expect(SeasonRecap.lock(season: "2026-27", owned: [], current: "2026-27") == .ticket)            // 이번 시즌 미구입 → S18
        #expect(SeasonRecap.lock(season: "2025-26", owned: [], current: "2026-27") == .pastSeason)        // 지난 시즌 미구입 → 안내
        #expect(SeasonRecap.lock(season: "2025-26", owned: ["2025-26"], current: "2026-27") == .open)    // 지난 시즌 구입 → 열림
        #expect(SeasonRecap.lock(season: "2025-26", owned: ["2026-27"], current: "2026-27") == .pastSeason) // 이번 시즌만 → 잠김
    }
}
