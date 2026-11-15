import Foundation
import Testing
@testable import SlopeMate

struct SeasonGoalTests {
    let defaults = UserDefaults(suiteName: "SeasonGoalTests-\(UUID().uuidString)")!

    @Test func savesPerSeason() {
        #expect(SeasonGoal.load(season: "2026-27", defaults: defaults) == nil)
        SeasonGoal.save(SeasonGoal(days: 10, runs: nil), season: "2026-27", defaults: defaults)
        SeasonGoal.save(SeasonGoal(days: nil, runs: 200), season: "2025-26", defaults: defaults)
        #expect(SeasonGoal.load(season: "2026-27", defaults: defaults) == SeasonGoal(days: 10, runs: nil))
        #expect(SeasonGoal.load(season: "2025-26", defaults: defaults) == SeasonGoal(days: nil, runs: 200))
        #expect(SeasonGoal.load(season: "2027-28", defaults: defaults) == nil)
        // 빈 목표·nil은 지운다
        SeasonGoal.save(SeasonGoal(), season: "2026-27", defaults: defaults)
        #expect(SeasonGoal.load(season: "2026-27", defaults: defaults) == nil)
        SeasonGoal.save(nil, season: "2025-26", defaults: defaults)
        #expect(SeasonGoal.load(season: "2025-26", defaults: defaults) == nil)
    }

    @Test func progressClampsButKeepsValue() {
        let p = SeasonGoal(days: 10, runs: 100).progress(visitDays: 12, runs: 84)
        #expect(p.days == .init(value: 12, target: 10))
        #expect(p.days?.fraction == 1 && p.days?.done == true && p.days?.left == 0)
        #expect(p.runs?.fraction == 0.84 && p.runs?.done == false && p.runs?.left == 16)
        let exact = SeasonGoal.Progress(value: 10, target: 10)
        #expect(exact.done && exact.fraction == 1)
        let one = SeasonGoal(days: nil, runs: 50).progress(visitDays: 3, runs: 0)
        #expect(one.days == nil && one.runs?.fraction == 0)
    }

    @Test func stepperBounds() {
        func d(_ v: Int, _ up: Bool) -> Int { SeasonGoal.step(v, up: up, by: SeasonGoal.dayStep, max: SeasonGoal.maxDays) }
        func r(_ v: Int, _ up: Bool) -> Int { SeasonGoal.step(v, up: up, by: SeasonGoal.runStep, max: SeasonGoal.maxRuns) }
        #expect(d(10, true) == 11 && d(10, false) == 9 && d(1, false) == 1 && d(180, true) == 180)
        #expect(r(100, true) == 110 && r(100, false) == 90)
        #expect(r(10, false) == 1 && r(1, false) == 1 && r(1, true) == 10)
        #expect(r(9_990, true) == 9_990 && r(9_985, true) == 9_990)
    }
}
