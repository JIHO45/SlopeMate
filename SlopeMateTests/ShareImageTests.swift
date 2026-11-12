import Foundation
import Testing
import UIKit
@testable import SlopeMate

@MainActor struct ShareImageTests {
    let f = ISO8601DateFormatter()
    func at(_ s: String) -> Date { f.date(from: s + "+09:00")! }
    func run(_ start: String, _ end: String) -> RunDetector.Run {
        RunDetector.Run(start: at(start), end: at(end), distance: 1200, drop: 300, maxSpeed: 15, avgSpeed: 8, movingTime: 150)
    }
    var day: Stats.Day {
        Stats.Day(date: at("2026-12-06T06:00:00"), resortId: "high1", runs: [
            run("2026-12-06T09:40:00", "2026-12-06T09:45:00"), run("2026-12-06T16:15:00", "2026-12-06T16:20:00"),
            run("2026-12-06T18:30:00", "2026-12-06T18:35:00"),
            run("2026-12-06T22:40:00", "2026-12-06T22:45:00"), run("2026-12-07T01:25:00", "2026-12-07T01:30:00"),
            run("2026-12-06T17:00:00", "2026-12-06T17:05:00")], usedGPSAltitude: false)
    }

    @Test func sessionsInOrderWithNextDayAndUnclassified() {
        let kinds: [SessionKind?] = [.day, .day, .night, .lateNight, .lateNight, nil]
        let runs = day.runs
        let c = ShareImage.content(day, resort: "하이원") { r in kinds[runs.firstIndex(of: r)!] }
        #expect(c.date == "2026년 12월 6일 일요일")
        #expect(c.runs == 6)
        #expect(c.distance == "7.2")
        #expect(c.sessions == [
            .init(name: "주간", time: "09:40~16:20", runs: 2),
            .init(name: "야간", time: "18:30~18:35", runs: 1),
            .init(name: "심야", time: "22:40~다음 날 01:30", runs: 2),
            .init(name: "미분류", time: nil, runs: 1)])
    }

    @Test func noTimetableMeansNoSessionCard() {
        #expect(ShareImage.content(day, resort: "하이원").sessions.isEmpty)
    }

    @Test func sessionStartingAfterMidnightSaysNextDayOnce() {
        #expect(ShareImage.span(at("2026-12-07T00:10:00"), at("2026-12-07T01:30:00"), day: at("2026-12-06T06:00:00")) == "다음 날 00:10~01:30")
    }

    @Test func rendersAt1080x1350() throws {
        let image = try #require(ShareImage.render(ShareImage.content(day, resort: "하이원")))
        #expect(image.size.width * image.scale == 1080)
        #expect(image.size.height * image.scale == 1350)
    }
}
