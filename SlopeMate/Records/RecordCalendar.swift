import Foundation

/// 기록 달력(S8·S9) 날짜 계산. 주는 일요일 시작, "n월 n주"는 그 주 목요일이 속한 달 기준.
nonisolated enum RecordCalendar {
    static var cal: Calendar {
        var c = HomeData.seoul
        c.firstWeekday = 1
        return c
    }

    /// 달력 날짜 00:00 (Stats.Day.date는 06:00)
    static func dayStart(_ d: Date) -> Date { cal.startOfDay(for: d) }

    static func weekStart(_ d: Date) -> Date {
        let day = dayStart(d)
        return cal.date(byAdding: .day, value: 1 - cal.component(.weekday, from: day), to: day)!
    }

    static func weekDays(_ start: Date) -> [Date] {
        (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
    }

    /// 11월 1일이 든 주부터 이번 주(또는 4월 30일이 든 주)까지. 시즌 전이면 빈 배열.
    static func weeks(season: String, now: Date = .now) -> [Date] {
        let first = HomeData.seasonStart(season)
        let today = BusinessDay.start(of: now)
        guard today >= first else { return [] }
        let y = cal.component(.year, from: first) + 1
        let last = min(weekStart(today), weekStart(cal.date(from: DateComponents(year: y, month: 4, day: 30))!))
        var out: [Date] = []
        var w = weekStart(first)
        while w <= last {
            out.append(w)
            w = cal.date(byAdding: .day, value: 7, to: w)!
        }
        return out
    }

    static func weekLabel(_ start: Date) -> (month: String, week: String) {
        let thu = cal.dateComponents([.month, .day], from: cal.date(byAdding: .day, value: 4, to: start)!)
        return ("\(thu.month!)월", "\((thu.day! - 1) / 7 + 1)주")
    }

    static func weekRange(_ start: Date) -> String {
        let a = cal.dateComponents([.month, .day], from: start)
        let b = cal.dateComponents([.month, .day], from: cal.date(byAdding: .day, value: 6, to: start)!)
        return "\(a.month!)월 \(a.day!)일 ~ " + (a.month == b.month ? "\(b.day!)일" : "\(b.month!)월 \(b.day!)일")
    }

    static func days(_ days: [Stats.Day], in interval: DateInterval) -> [Stats.Day] {
        days.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    /// 11월 ~ 4월 각 달 1일 00:00
    static func seasonMonths(_ season: String) -> [Date] {
        let y = Int(season.prefix(4)) ?? 2026
        return (0..<6).map { cal.date(from: DateComponents(year: y, month: 11 + $0))! }
    }

    /// 일요일 시작 달력 칸: 앞 빈칸은 nil
    static func monthGrid(_ month: Date) -> [Date?] {
        let m = monthInterval(month)
        let lead = cal.component(.weekday, from: m.start) - 1
        let n = cal.range(of: .day, in: .month, for: m.start)!.count
        return Array(repeating: nil, count: lead) + (0..<n).map { cal.date(byAdding: .day, value: $0, to: m.start) }
    }

    static func weekInterval(_ start: Date) -> DateInterval {
        DateInterval(start: start, end: cal.date(byAdding: .day, value: 7, to: start)!)
    }

    static func monthInterval(_ m: Date) -> DateInterval { cal.dateInterval(of: .month, for: m)! }

    /// 한 달 합계와 지난달 대비 방문일 차이. 시즌 첫 달(11월)은 비교하지 않는다(nil).
    static func monthTotals(_ days: [Stats.Day], month: Date, season: String) -> (totals: Stats.Totals, visitDelta: Int?) {
        let m = monthInterval(month)
        let t = Stats.totals(Self.days(days, in: m))
        guard m.start != seasonMonths(season).first, let prev = cal.date(byAdding: .month, value: -1, to: m.start) else { return (t, nil) }
        return (t, t.visitDays - Stats.totals(Self.days(days, in: monthInterval(prev))).visitDays)
    }
}
