import Foundation
import Testing
@testable import SlopeMate

struct RecordCalendarTests {
    func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 0) -> Date {
        RecordCalendar.cal.date(from: DateComponents(year: y, month: m, day: day, hour: h))!
    }

    @Test func weekStartsSunday() {
        #expect(RecordCalendar.weekStart(d(2026, 11, 25, 15)) == d(2026, 11, 22))
        #expect(RecordCalendar.weekDays(d(2026, 11, 22)).count == 7)
        #expect(RecordCalendar.weekDays(d(2026, 11, 22)).last == d(2026, 11, 28))
        #expect(RecordCalendar.dayStart(d(2026, 11, 25, 6)) == d(2026, 11, 25))
    }

    @Test func weekLabelUsesThursday() {
        #expect(RecordCalendar.weekLabel(d(2026, 11, 1)) == ("11월", "1주"))
        #expect(RecordCalendar.weekLabel(d(2026, 11, 22)) == ("11월", "4주"))
        #expect(RecordCalendar.weekLabel(d(2026, 11, 29)) == ("12월", "1주"))
    }

    @Test func weekRange() {
        #expect(RecordCalendar.weekRange(d(2026, 12, 20)) == "12월 20일 ~ 26일")
        #expect(RecordCalendar.weekRange(d(2026, 11, 29)) == "11월 29일 ~ 12월 5일")
    }

    @Test func seasonWeeks() {
        #expect(RecordCalendar.weeks(season: "2026-27", now: d(2026, 10, 30, 12)).isEmpty)
        // 11월 1일 새벽은 아직 10월 31일 영업일
        #expect(RecordCalendar.weeks(season: "2026-27", now: d(2026, 11, 1, 3)).isEmpty)
        let now = RecordCalendar.weeks(season: "2026-27", now: d(2026, 11, 21, 12))
        #expect(now == [d(2026, 11, 1), d(2026, 11, 8), d(2026, 11, 15)])
        let all = RecordCalendar.weeks(season: "2026-27", now: d(2027, 6, 1))
        #expect(all.first == d(2026, 11, 1))
        #expect(all.last == d(2027, 4, 25))
        #expect(all.count == 26)
    }

    @Test func lateNightRunGoesToPreviousBusinessDayWeek() {
        // 일요일 02:00 하강은 토요일 영업일 → 앞 주
        let day = Stats.Day(date: BusinessDay.start(of: d(2026, 11, 29, 2)), resortId: "high1", runs: [], usedGPSAltitude: false)
        let sunday = Stats.Day(date: BusinessDay.start(of: d(2026, 11, 29, 10)), resortId: "high1", runs: [], usedGPSAltitude: false)
        #expect(RecordCalendar.days([day, sunday], in: RecordCalendar.weekInterval(d(2026, 11, 22))).map(\.date) == [day.date])
        #expect(RecordCalendar.days([day, sunday], in: RecordCalendar.weekInterval(d(2026, 11, 29))).map(\.date) == [sunday.date])
    }

    @Test func monthGrid() {
        let g = RecordCalendar.monthGrid(d(2026, 12, 1))
        #expect(g.prefix(2) == [nil, nil])
        #expect(g[2] == d(2026, 12, 1))
        #expect(g.compactMap { $0 }.count == 31)
        #expect(RecordCalendar.monthGrid(d(2026, 11, 1)).first == d(2026, 11, 1))
    }

    @Test func seasonMonths() {
        let m = RecordCalendar.seasonMonths("2026-27")
        #expect(m == [d(2026, 11, 1), d(2026, 12, 1), d(2027, 1, 1), d(2027, 2, 1), d(2027, 3, 1), d(2027, 4, 1)])
        #expect(RecordCalendar.monthInterval(d(2026, 12, 15)) == DateInterval(start: d(2026, 12, 1), end: d(2027, 1, 1)))
    }

    func day(_ y: Int, _ m: Int, _ dd: Int, _ resort: String = "high1", runs n: Int = 1) -> Stats.Day {
        let t = d(y, m, dd, 10)
        let run = RunDetector.Run(start: t, end: t + 60, distance: 1000, drop: 200, maxSpeed: 10, avgSpeed: 8, movingTime: 60)
        return Stats.Day(date: BusinessDay.start(of: t), resortId: resort, runs: Array(repeating: run, count: n), usedGPSAltitude: false)
    }

    @Test func monthTotalsAndDelta() {
        let s = "2026-27"
        // 11월 2일(두 리조트 같은 날 = 방문 1일) + 하강 0회 하루, 12월 3일
        let days = [day(2026, 11, 7), day(2026, 11, 7, "yongpyong", runs: 2), day(2026, 11, 8, runs: 0), day(2026, 11, 14),
                    day(2026, 12, 5), day(2026, 12, 6), day(2026, 12, 12)]
        let nov = RecordCalendar.monthTotals(days, month: d(2026, 11, 1), season: s)
        #expect(nov.totals.visitDays == 2)
        #expect(nov.totals.runs == 4)
        #expect(nov.totals.distance == 4000)
        #expect(nov.visitDelta == nil) // 시즌 첫 달
        #expect(RecordCalendar.monthTotals(days, month: d(2026, 12, 1), season: s).visitDelta == 1)
        #expect(RecordCalendar.monthTotals(days, month: d(2027, 1, 1), season: s).visitDelta == -3)
        #expect(RecordCalendar.monthTotals(days + [day(2027, 1, 2), day(2027, 1, 3), day(2027, 1, 9)],
                                           month: d(2027, 1, 1), season: s).visitDelta == 0)
    }
}
