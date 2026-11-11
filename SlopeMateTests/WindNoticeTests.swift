import Foundation
import Testing
@testable import SlopeMate

/// 오늘 운영 구간(R34)과 강풍 안내(R35). 06-verification R34·R35 항목.
struct WindNoticeTests {
    let f = ISO8601DateFormatter()
    func at(_ s: String) -> Date { f.date(from: s + "+09:00")! }

    typealias S = Timetable.Session
    func tt(_ sessions: [S], version: Int = 1, verified: String? = "2026-27",
            from: String = "2026-11-01", to: String = "2027-04-30") -> Timetable {
        Timetable(resortId: "high1", version: version, validFrom: from, validTo: to,
                  updatedAt: at("2026-11-05T12:00:00"), sessions: sessions, verifiedSeason: verified)
    }
    // 주간 08:30~16:30, 야간 18:30~22:00, 심야 22:00~03:00
    var basic: [S] { [S(kind: .day, start: "08:30", end: "16:30"),
                      S(kind: .night, start: "18:30", end: "22:00"),
                      S(kind: .lateNight, start: "22:00", end: "03:00")] }

    func today(_ t: String, _ list: [Timetable]) -> [Timetable.Open]? {
        Timetable.today(resortId: "high1", now: at(t), timetables: list)
    }

    /// 매시 정각 예보. speeds[i]는 start + i시간
    func hours(from start: String, _ speeds: [Double]) -> [WeatherSnapshot.Hour] {
        speeds.enumerated().map { i, w in
            WeatherSnapshot.Hour(date: at(start).addingTimeInterval(Double(i) * 3600), temperature: -5, symbolName: "sun.max",
                                 precipitationChance: 0, windSpeed: w, humidity: 0.5, snowfall: nil)
        }
    }

    /// 하루 내내 같은 바람, 단 h시(영업일 기준 정각)만 다른 값
    func day(_ base: Double, spike: [String: Double]) -> [WeatherSnapshot.Hour] {
        let list = hours(from: "2026-12-10T06:00:00", Array(repeating: base, count: 30))
        return list.map { h in
            var h = h
            let key = f.string(from: h.date)
            for (t, w) in spike where f.string(from: at(t)) == key { h.windSpeed = w }
            return h
        }
    }

    func notice(_ now: String, _ hs: [WeatherSnapshot.Hour], _ list: [Timetable]) -> WindNotice? {
        WindNotice.evaluate(hours: hs, now: at(now), today: today(now, list))
    }

    // MARK: 오늘 운영 구간

    @Test func verifiedTodayHasKindsAndNextDay() throws {
        let open = try #require(today("2026-12-10T10:00:00", [tt(basic)]))
        #expect(open.map(\.kind) == [.day, .night, .lateNight])
        #expect(open.map(\.nextDay) == [false, false, true])
        #expect(open[2].interval.end == at("2026-12-11T03:00:00"))
    }

    @Test func separateAfterMidnightIsNextDay() throws {
        let list = [tt([S(kind: .night, start: "18:00", end: "24:00"), S(kind: .lateNight, start: "00:00", end: "02:00")])]
        let open = try #require(today("2026-12-10T10:00:00", list))
        #expect(open.map(\.nextDay) == [false, true])
        #expect(open[1].interval.start == at("2026-12-11T00:00:00"))
    }

    @Test func endingAtMidnightWrittenAsZeroIsNextDay() throws {
        let list = [tt([S(kind: .lateNight, start: "22:00", end: "00:00"), S(kind: .night, start: "18:00", end: "24:00")])]
        let open = try #require(today("2026-12-10T10:00:00", list))
        #expect(open.map(\.end) == ["24:00", "00:00"])
        #expect(open.map(\.nextDay) == [false, true])
        #expect(open[1].interval.end == at("2026-12-11T00:00:00"))
    }

    @Test func unverifiedOrOldSeasonIsNil() {
        #expect(today("2026-12-10T10:00:00", [tt(basic, verified: nil)]) == nil)
        #expect(today("2026-12-10T10:00:00", [tt(basic, verified: "2025-26")]) == nil)
        #expect(today("2026-12-10T10:00:00", [tt(basic, from: "2027-01-01")]) == nil) // 적용 기간 밖
    }

    @Test func latestVersionDecidesEvenIfUnverified() {
        let list = [tt(basic, version: 1), tt(basic, version: 2, verified: nil)]
        #expect(today("2026-12-10T10:00:00", list) == nil)
    }

    @Test func offSeasonWithoutVerifiedIsNil() {
        // 비시즌(5~10월)은 시즌 값이 없어 verifiedSeason nil과 같아도 확인으로 보지 않는다
        let list = [tt(basic, verified: nil, from: "2026-05-01", to: "2026-10-31")]
        #expect(today("2026-07-10T10:00:00", list) == nil)
    }

    @Test func noSessionForWeekdayIsEmpty() {
        let list = [tt([S(kind: .day, start: "09:00", end: "16:00", weekdays: [6, 7])])]
        #expect(today("2026-12-10T10:00:00", list) == [])  // 목요일
    }

    @Test func businessDayBoundary() throws {
        // 05:59는 전날(수요일) 영업일, 06:00부터 목요일 영업일
        let list = [tt([S(kind: .day, start: "09:00", end: "16:00", weekdays: [5])])]
        #expect(today("2026-12-10T05:59:00", list) == [])
        #expect(try #require(today("2026-12-10T06:00:00", list)).count == 1)
    }

    @Test func decodesWithAndWithoutVerifiedSeason() throws {
        let json = """
        [{"resortId":"high1","version":1,"validFrom":"2026-11-01","validTo":"2027-04-30","updatedAt":"2026-11-05T03:00:00Z",
          "sessions":[{"kind":"day","start":"09:00","end":"16:00"}],"verifiedSeason":"2026-27"},
         {"resortId":"vivaldi","version":1,"validFrom":"2026-11-01","validTo":"2027-04-30","updatedAt":"2026-11-05T03:00:00Z",
          "sessions":[]}]
        """
        let list = try Timetable.decode(Data(json.utf8))
        #expect(list.map(\.verifiedSeason) == ["2026-27", nil])
    }

    // MARK: 강풍 안내

    @Test func thresholdBelowEqualAbove() {
        let list = [tt(basic)]
        #expect(notice("2026-12-10T10:00:00", day(9.9, spike: [:]), list) == nil)
        #expect(notice("2026-12-10T10:00:00", day(9.9, spike: ["2026-12-10T12:00:00": 10]), list)?.maxSpeed == 10)
        #expect(notice("2026-12-10T10:00:00", day(9.9, spike: ["2026-12-10T12:00:00": 14]), list)
                == WindNotice(maxSpeed: 14, scope: .remainingHours))
    }

    @Test func currentHourIncludedAtHalfPast() {
        // 10:30이면 10시 예보 포함, 9시 예보는 지났으므로 제외
        let list = [tt(basic)]
        #expect(notice("2026-12-10T10:30:00", day(3, spike: ["2026-12-10T10:00:00": 12]), list) != nil)
        #expect(notice("2026-12-10T10:30:00", day(3, spike: ["2026-12-10T09:00:00": 12]), list) == nil)
    }

    @Test func closingAtHalfPastIncludesThatHour() {
        let list = [tt([S(kind: .day, start: "09:00", end: "22:30")])]
        #expect(notice("2026-12-10T20:00:00", day(3, spike: ["2026-12-10T22:00:00": 12]), list) != nil)
        #expect(notice("2026-12-10T20:00:00", day(3, spike: ["2026-12-10T23:00:00": 12]), list) == nil)
    }

    @Test func openingAtHalfPastIncludesThatHour() {
        // 08:30 개장: 8시 예보는 운영과 겹쳐 포함, 7시 예보는 겹치지 않아 제외
        let list = [tt(basic)]
        #expect(notice("2026-12-10T06:30:00", day(3, spike: ["2026-12-10T08:00:00": 12]), list) != nil)
        #expect(notice("2026-12-10T06:30:00", day(3, spike: ["2026-12-10T07:00:00": 12]), list) == nil)
    }

    @Test func groomingGapExcluded() {
        // 16:30~18:30 정설: 17시 예보는 어느 운영 구간과도 겹치지 않는다
        let list = [tt(basic)]
        #expect(notice("2026-12-10T16:40:00", day(3, spike: ["2026-12-10T17:00:00": 15]), list) == nil)
        #expect(notice("2026-12-10T16:40:00", day(3, spike: ["2026-12-10T18:00:00": 15]), list) != nil)
    }

    @Test func lateNightIncluded() {
        let list = [tt(basic)]
        #expect(notice("2026-12-10T23:00:00", day(3, spike: ["2026-12-11T02:00:00": 13]), list) != nil)
    }

    @Test func afterVerifiedClosingNoNotice() {
        // 22:00 폐장(심야 없음) 뒤 새벽 강풍: 확인된 시간표라 남은 구간이 없으면 안내 안 함
        let list = [tt([S(kind: .day, start: "09:00", end: "16:00"), S(kind: .night, start: "18:00", end: "22:00")])]
        #expect(notice("2026-12-10T22:30:00", day(3, spike: ["2026-12-11T02:00:00": 15]), list) == nil)
        // 요일 구간이 없는 날도 안내 안 함
        let weekend = [tt([S(kind: .day, start: "09:00", end: "16:00", weekdays: [6, 7])])]
        #expect(notice("2026-12-10T10:00:00", day(15, spike: [:]), weekend) == nil)
    }

    @Test func unverifiedUsesNext24h() {
        let list = [tt(basic, verified: nil)]
        let n = notice("2026-12-10T22:30:00", day(3, spike: ["2026-12-11T05:00:00": 12]), list)
        #expect(n == WindNotice(maxSpeed: 12, scope: .next24h))
        #expect(n?.title == "바람 최대 12m/s · 향후 24시간 예보")
    }

    @Test func emptyForecastIsNotNoWind() {
        #expect(WindNotice.evaluate(hours: [], now: at("2026-12-10T10:00:00"), today: nil) == nil)
    }

    @Test func wordingHasNoLiftPrediction() {
        let text = WindNotice(maxSpeed: 14, scope: .remainingHours).title + WindNotice.hint
        for word in ["운휴", "중단", "위험", "안전", "멈"] { #expect(!text.contains(word)) }
    }
}
