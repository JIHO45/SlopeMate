import Foundation
import Testing
@testable import SlopeMate

struct StatsTests {
    let f = ISO8601DateFormatter()
    func at(_ s: String) -> Date { f.date(from: s + "+09:00")! }

    func rec(_ resort: String, _ start: String) -> Recording {
        Recording(id: UUID(), resortId: resort, startedAt: at(start))
    }
    func run(_ start: String, km: Double = 1, drop: Double = 300, maxSpeed: Double = 15, moving: Double = 200) -> RunDetector.Run {
        RunDetector.Run(start: at(start), end: at(start) + moving, distance: km * 1000, drop: drop,
                        maxSpeed: maxSpeed, avgSpeed: km * 1000 / moving, movingTime: moving)
    }
    func summary(_ runs: RunDetector.Run...) -> RunDetector.Summary { RunDetector.Summary(runs: runs) }

    @Test func lateNightRunBelongsToPreviousBusinessDay() {
        let days = Stats.days([(rec("high1", "2026-12-05T21:00:00"),
                                summary(run("2026-12-05T22:00:00"), run("2026-12-06T01:30:00")))])
        #expect(days.count == 1)
        #expect(days[0].date == at("2026-12-05T06:00:00"))
        #expect(days[0].runs.count == 2)
    }

    @Test func severalRecordingsSameDayAreOneVisit() {
        let days = Stats.days([(rec("high1", "2026-12-05T09:00:00"), summary(run("2026-12-05T09:10:00"))),
                               (rec("high1", "2026-12-05T19:00:00"), summary(run("2026-12-05T19:10:00")))])
        #expect(days.count == 1)
        #expect(Stats.totals(days).visitDays == 1)
        #expect(Stats.totals(days).runs == 2)
    }

    @Test func twoResortsOneDay() {
        let days = Stats.days([(rec("high1", "2026-12-05T09:00:00"), summary(run("2026-12-05T09:10:00"))),
                               (rec("o2", "2026-12-05T15:00:00"), summary(run("2026-12-05T15:10:00")))])
        #expect(Stats.totals(days).visitDays == 1)
        let by = Stats.totalsByResort(days)
        #expect(by["high1"]?.visitDays == 1 && by["o2"]?.visitDays == 1)
    }

    @Test func gpsAltitudeWarningIgnoresOrder() {
        // GPS 고도로 판정한 기록이 전날 시작해 06:00을 넘긴 하강을 갖고, 그 영업일에 기압 기록이 따로 있음
        var gps = summary(run("2026-12-05T07:00:00"))
        gps.usedGPSAltitude = true
        let late = (rec("high1", "2026-12-04T21:00:00"), gps)
        let baro = (rec("high1", "2026-12-05T09:00:00"), summary(run("2026-12-05T09:10:00")))
        for input in [[baro, late], [late, baro]] {
            let day = Stats.days(input).first { $0.date == at("2026-12-05T06:00:00") }
            #expect(day?.usedGPSAltitude == true)
        }
    }

    @Test func recordingWithoutRunsIsNotAVisit() {
        let days = Stats.days([(rec("high1", "2026-12-05T09:00:00"), summary())])
        #expect(days.count == 1 && !days[0].isVisit)
        #expect(Stats.totals(days).visitDays == 0)
    }

    @Test func totals() {
        let days = Stats.days([(rec("high1", "2026-12-05T09:00:00"),
                                summary(run("2026-12-05T09:10:00", km: 1, maxSpeed: 15, moving: 100),
                                        run("2026-12-05T09:40:00", km: 2, maxSpeed: 20, moving: 300)))])
        let t = Stats.totals(days)
        #expect(t.distance == 3000 && t.drop == 600 && t.maxSpeed == 20)
        #expect(t.avgSpeed == 3000.0 / 400) // 정지 시간 뺀 평균
    }

    @Test func season() {
        #expect(Stats.season(of: at("2026-11-01T06:00:00")) == "2026-27")
        #expect(Stats.season(of: at("2027-04-30T06:00:00")) == "2026-27")
        #expect(Stats.season(of: at("2026-10-31T06:00:00")) == nil)
        #expect(Stats.season(of: at("2027-05-01T06:00:00")) == nil)
        #expect(Stats.season(of: at("2099-12-01T06:00:00")) == "2099-00")
        // 5월 1일 새벽 심야 하강은 4월 30일 영업일 → 시즌 안
        #expect(Stats.season(of: BusinessDay.start(of: at("2027-05-01T02:00:00"))) == "2026-27")
    }
}
