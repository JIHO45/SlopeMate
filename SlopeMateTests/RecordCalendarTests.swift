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
}
