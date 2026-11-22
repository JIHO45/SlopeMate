import Foundation
import Testing
@testable import SlopeMate

struct ResortBrowseTests {
    private func slope(_ difficulty: String?) -> SlopeMap.Slope {
        SlopeMap.Slope(id: UUID().uuidString, name: nil, difficulty: difficulty, osmIds: ["1"], lines: [], area: nil)
    }

    /// OSM 슬로프에 이어지지 않은 그린 선 조각은 세지 않는다
    @Test func drawnOnlyLinesAreNotCounted() {
        let loose = SlopeMap.Slope(id: "x-d01", name: nil, difficulty: "easy", osmIds: [], lines: [], area: nil)
        #expect(DifficultyCounts([slope("easy"), loose]).total == 1)
    }

    @Test func countsPerLevel() {
        let c = DifficultyCounts(["easy", "novice", "intermediate", "expert", "freeride", nil, "weird"].map(slope))
        #expect(c.count(.beginner) == 2)
        #expect(c.count(.intermediate) == 1)
        #expect(c.count(.advanced) == 0)
        #expect(c.count(.expert) == 2)
        #expect(c.unknown == 2)
        #expect(c.total == 7)
    }

    @Test func segmentsDropZeroKeepOrderSumToOne() {
        let c = DifficultyCounts(["expert", "easy", "easy", "intermediate", nil].map(slope))
        #expect(c.segments.map(\.level) == [.beginner, .intermediate, .expert])
        #expect(c.segments.map(\.count) == [2, 1, 1])
        #expect(abs(c.segments.map(\.ratio).reduce(0, +) - 1) < 1e-9)
    }

    @Test func noKnownSlopesHasNoSegments() {
        #expect(DifficultyCounts([nil].map(slope)).segments.isEmpty)
        #expect(DifficultyCounts([]).total == 0)
    }

    @MainActor @Test func bundledResortsHaveSlopes() throws {
        #expect(Resort.all.count == 12)
        for r in Resort.all {
            let c = try #require(DifficultyCounts.of(r.id), "\(r.id)")
            #expect(c.total > 0, "\(r.id)")
        }
    }

    private func pass(_ name: String, order: Int) -> SeasonPass {
        SeasonPass(id: UUID(), season: "2026-27", name: name, price: 600_000, sortOrder: order)
    }

    private func day(_ resort: String) -> Stats.Day {
        let d = ISO8601DateFormatter().date(from: "2026-12-05T06:00:00+09:00")!
        let run = RunDetector.Run(start: d.addingTimeInterval(14_400), end: d.addingTimeInterval(14_700), distance: 1000, drop: 300,
                                  maxSpeed: 10, avgSpeed: 8, movingTime: 120)
        return Stats.Day(date: d, resortId: resort, runs: [run], usedGPSAltitude: false)
    }

    @Test func resortPassPicksUpperOverlappingPass() throws {
        let a = pass("A", order: 1), b = pass("B", order: 0)
        let passes = [(pass: a, resorts: ["high1", "o2"]), (pass: b, resorts: ["high1"])]
        let s = try #require(PassSummary.forResort("high1", passes: passes, days: [day("high1")], season: "2026-27"))
        #expect(s.label == "B")
        #expect(s.value == PassValue.Value(visits: 1, price: 600_000))
        // 오투는 A만 포함, 방문 0일이면 금액 없음
        #expect(PassSummary.forResort("o2", passes: passes, days: [day("high1")], season: "2026-27") == PassSummary(label: "A", value: nil))
    }

    @Test func resortWithoutPassHasNone() {
        let passes = [(pass: pass("A", order: 0), resorts: ["high1"])]
        #expect(PassSummary.forResort("vivaldi", passes: passes, days: [], season: "2026-27") == nil)
        #expect(PassSummary.forResort("high1", passes: passes, days: [], season: "2025-26") == nil)
    }
}
