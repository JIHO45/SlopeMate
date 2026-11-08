import Foundation
import Testing
@testable import SlopeMate

struct TimetableTests {
    let f = ISO8601DateFormatter()
    func at(_ s: String) -> Date { f.date(from: s + "+09:00")! }

    typealias S = Timetable.Session
    func tt(_ sessions: [S], resort: String = "high1", version: Int = 1,
            from: String = "2026-11-01", to: String = "2027-04-30",
            updated: String = "2026-11-05T12:00:00") -> Timetable {
        Timetable(resortId: resort, version: version, validFrom: from, validTo: to,
                  updatedAt: at(updated), sessions: sessions)
    }
    // 주간 09:00~16:00, 정설 16:00~18:00, 야간 18:00~22:00, 심야 22:00~03:00
    var basic: [S] { [S(kind: .day, start: "09:00", end: "16:00"),
                      S(kind: .night, start: "18:00", end: "22:00"),
                      S(kind: .lateNight, start: "22:00", end: "03:00")] }

    func kind(_ t: String, _ list: [Timetable], resort: String = "high1") -> SessionKind? {
        Timetable.session(at: at(t), resortId: resort, timetables: list)
    }

    /// 요일마다 시간이 다른 리조트: 같은 세션을 요일별로 여러 줄 적는다.
    /// 월~목 주간 09:00~16:30·야간 18:30~22:30, 금~일 주간 08:00~16:30·야간 18:30~24:00, 금·토만 심야 00:00~03:00
    @Test func differentHoursByWeekday() {
        let weekday = [2, 3, 4, 5], weekend = [6, 7, 1]
        let list = [tt([S(kind: .day, start: "09:00", end: "16:30", weekdays: weekday),
                        S(kind: .day, start: "08:00", end: "16:30", weekdays: weekend),
                        S(kind: .night, start: "18:30", end: "22:30", weekdays: weekday),
                        S(kind: .night, start: "18:30", end: "24:00", weekdays: weekend),
                        S(kind: .lateNight, start: "00:00", end: "03:00", weekdays: [6, 7])])]
        #expect(kind("2026-12-10T08:30:00", list) == .unclassified) // 목요일 08:30: 아직 주간 전
        #expect(kind("2026-12-11T08:30:00", list) == .day)          // 금요일 08:30
        #expect(kind("2026-12-10T23:00:00", list) == .unclassified) // 목요일 23:00: 야간 끝
        #expect(kind("2026-12-11T23:00:00", list) == .night)        // 금요일 23:00
        #expect(kind("2026-12-12T01:00:00", list) == .lateNight)    // 금요일 영업일의 토요일 새벽
        #expect(kind("2026-12-14T01:00:00", list) == .unclassified) // 일요일 영업일의 월요일 새벽: 심야 없음
    }

    @Test func dayNightLate() {
        let list = [tt(basic)]
        #expect(kind("2026-12-10T10:00:00", list) == .day)
        #expect(kind("2026-12-10T19:00:00", list) == .night)
        #expect(kind("2026-12-10T23:00:00", list) == .lateNight)
    }

    @Test func lateSessionCatchesNextCalendarDay() {
        #expect(kind("2026-12-11T01:30:00", [tt(basic)]) == .lateNight)
        #expect(kind("2026-12-11T03:30:00", [tt(basic)]) == .unclassified)
    }

    @Test func afterMidnightSessionWrittenSeparately() {
        let list = [tt([S(kind: .night, start: "18:00", end: "24:00"),
                        S(kind: .lateNight, start: "00:00", end: "02:00")])]
        #expect(kind("2026-12-10T23:00:00", list) == .night)
        #expect(kind("2026-12-11T01:00:00", list) == .lateNight)
        #expect(kind("2026-12-11T02:30:00", list) == .unclassified)
    }

    @Test func groomingGapIsUnclassified() {
        #expect(kind("2026-12-10T17:00:00", [tt(basic)]) == .unclassified)
    }

    @Test func weekdaysFollowBusinessDay() {
        // 심야는 금(6)·토(7) 밤만
        let list = [tt([S(kind: .night, start: "18:00", end: "22:00"),
                        S(kind: .lateNight, start: "22:00", end: "03:00", weekdays: [6, 7])])]
        #expect(kind("2026-12-05T01:00:00", list) == .lateNight)    // 금요일 밤(달력은 토)
        #expect(kind("2026-12-07T01:00:00", list) == .unclassified) // 일요일 밤(달력은 월)
    }

    @Test func outsideValidRangeIsNil() {
        let list = [tt(basic, from: "2026-12-01", to: "2026-12-31")]
        #expect(kind("2026-11-30T10:00:00", list) == nil)
        #expect(kind("2027-01-01T02:00:00", list) == .lateNight) // 12-31 영업일
        #expect(kind("2027-01-01T10:00:00", list) == nil)
        #expect(kind("2026-12-10T10:00:00", list, resort: "yongpyong") == nil)
    }

    @Test func higherVersionWins() {
        let v1 = tt(basic, version: 1)
        let v2 = tt([S(kind: .night, start: "09:00", end: "16:00")], version: 2, from: "2026-12-01", to: "2026-12-31")
        #expect(kind("2026-12-10T10:00:00", [v2, v1]) == .night)
        #expect(kind("2026-12-10T10:00:00", [v1, v2]) == .night)
        #expect(kind("2026-11-20T10:00:00", [v1, v2]) == .day)
    }

    @Test func staleUpdatedAtIsJudgedBySeasonOfDay() {
        let old = tt(basic, from: "2025-11-01", to: "2027-04-30", updated: "2026-03-15T12:00:00")
        #expect(kind("2026-12-10T10:00:00", [old]) == nil)  // 지난 시즌(2025-26) 중에 고침 → 2026-27에는 오래됨
        #expect(kind("2025-12-10T10:00:00", [old]) == .day) // 2025-26 시즌 기준이면 최신
        let preseason = tt(basic, from: "2026-11-01", to: "2027-04-30", updated: "2026-10-15T12:00:00")
        #expect(kind("2026-12-10T10:00:00", [preseason]) == .day) // 개장 전 입력은 이번 시즌용
        let offSeason = tt(basic, from: "2026-05-01", to: "2026-10-31", updated: "2026-11-05T12:00:00")
        #expect(kind("2026-07-10T10:00:00", [offSeason]) == nil)
    }

    @Test func boundariesAreHalfOpen() {
        let list = [tt(basic)]
        #expect(kind("2026-12-10T09:00:00", list) == .day)
        #expect(kind("2026-12-10T16:00:00", list) == .unclassified)
        #expect(kind("2026-12-10T22:00:00", list) == .lateNight)
        #expect(kind("2026-12-11T03:00:00", list) == .unclassified)
    }

    @Test func bundledDecodes() {
        _ = Timetable.all
    }
}
