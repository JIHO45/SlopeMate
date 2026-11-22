import Foundation
import Testing
@testable import SlopeMate

/// 내 리프트 대기 합계 (R32): 리프트별 묶음·순서, 영업일·시즌 거르기, 서버 설정 기본값
struct LiftWaitStatsTests {
    static func wait(_ resort: String, _ lift: String, _ min: Double, at t: String) -> LiftWait {
        let f = ISO8601DateFormatter()
        return LiftWait(recordingId: UUID(), boardAt: f.date(from: t)!, resortId: resort, liftId: lift, waitSec: min * 60, sendState: "pending")
    }

    @Test func groupsByLiftLongestFirst() {
        let s = LiftWaitStats.summary([
            Self.wait("high1", "g1", 6, at: "2026-11-29T01:00:00Z"),
            Self.wait("high1", "a", 11, at: "2026-11-29T02:00:00Z"),
            Self.wait("high1", "g1", 12, at: "2026-11-29T03:00:00Z"),
            Self.wait("high1", "a", 10, at: "2026-11-29T04:00:00Z"),
            Self.wait("yongpyong", "a", 8, at: "2026-11-30T01:00:00Z"),
        ])
        #expect(s.count == 5 && s.total == 47 * 60)
        #expect(s.lifts.map(\.liftId) == ["a", "g1", "a"])
        #expect(s.lifts.map(\.resortId) == ["high1", "high1", "yongpyong"]) // 같은 ID라도 리조트가 다르면 따로
        #expect(s.lifts[0].count == 2 && s.lifts[0].avg == 10.5 * 60)
        #expect(LiftWaitStats.summary([]) == .init())
    }

    @Test func dayAndSeasonFilters() {
        // 한국 05:30은 전날 영업일, 07:00은 그날
        let early = Self.wait("high1", "g1", 5, at: "2026-11-28T20:30:00Z")
        let morning = Self.wait("high1", "g1", 7, at: "2026-11-28T22:00:00Z")
        let other = Self.wait("yongpyong", "g1", 9, at: "2026-11-28T23:00:00Z")
        let lastSeason = Self.wait("high1", "g1", 4, at: "2026-03-01T01:00:00Z")
        let all = [early, morning, other, lastSeason]
        let day = Stats.Day(date: BusinessDay.start(of: morning.boardAt), resortId: "high1", runs: [], usedGPSAltitude: false)
        #expect(LiftWaitStats.day(all, day) == [morning])
        #expect(LiftWaitStats.season(all, "2026-27") == [early, morning, other])
        #expect(LiftWaitStats.season(all, "2025-26") == [lastSeason])
    }

    @Test func flagOffByDefault() throws {
        let old = try JSONDecoder().decode(ServerConfig.Config.self, from: Data(#"{"slopeNames":[],"crewSync":true,"samples":true}"#.utf8))
        #expect(!old.liftWait)
        let on = try JSONDecoder().decode(ServerConfig.Config.self, from: Data(#"{"slopeNames":[],"crewSync":true,"samples":true,"liftWait":true}"#.utf8))
        #expect(on.liftWait)
    }
}
