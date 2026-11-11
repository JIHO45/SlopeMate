import Foundation

/// 리조트 운영 시간표(R7). 리조트가 공개한 정보를 손으로 입력해 번들한다.
nonisolated struct Timetable: Codable, Hashable {
    struct Session: Codable, Hashable {
        enum Kind: String, Codable { case day, night, lateNight }
        var kind: Kind
        var start: String        // "HH:mm" 한국 시간
        var end: String          // "HH:mm", 시작보다 이르면 다음 날 (22:00~03:00)
        var weekdays: [Int]?     // 1=일 ... 7=토 (Calendar 기준), 없으면 매일. 영업일의 요일 기준
    }
    var resortId: String
    var version: Int
    var validFrom: String        // "yyyy-MM-dd" 영업일 날짜, 포함
    var validTo: String          // "yyyy-MM-dd" 영업일 날짜, 포함
    var updatedAt: Date          // ISO8601
    var sessions: [Session]
    /// 리조트 공식 안내와 손으로 대조한 시즌("2026-27"). 이번 시즌일 때만 운영 시간 표시(R34)·강풍 안내 구간(R35)에 쓴다.
    var verifiedSeason: String? = nil

    /// 앱에 내장한 시간표. 출시 뒤 고친 것은 서버(ServerConfig.timetables)에서 받아 합친다.
    static let all: [Timetable] = {
        let url = Bundle.main.url(forResource: "timetables", withExtension: "json")!
        return try! decode(Data(contentsOf: url))
    }()

    static func decode(_ data: Data) throws -> [Timetable] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode([Timetable].self, from: data)
    }

    /// 영업일의 시간표: 그 리조트·날짜를 덮는 것 중 버전이 가장 큰 것
    private struct Day {
        var timetable: Timetable
        var weekday: Int
        var midnight: Date       // 영업일 날짜의 0시
        var season: String?
    }

    private static func pick(_ t: Date, resortId: String, timetables: [Timetable]) -> Day? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let day = BusinessDay.start(of: t)
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: day)
        let date = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        // 문자열 비교로 충분하다(yyyy-MM-dd)
        guard let tt = timetables
            .filter({ $0.resortId == resortId && $0.validFrom <= date && date <= $0.validTo })
            .max(by: { $0.version < $1.version }) else { return nil }
        return Day(timetable: tt, weekday: c.weekday!, midnight: day.addingTimeInterval(-6 * 3600), season: Stats.season(of: day))
    }

    /// 그날 요일에 맞는 세션의 영업일 0시 기준 분 구간. 새벽 1시는 25:00(1500분)
    private static func spans(_ d: Day) -> [(Session, Int, Int)] {
        d.timetable.sessions.compactMap { s in
            if let w = s.weekdays, !w.contains(d.weekday) { return nil }
            guard var a = minutes(s.start), var b = minutes(s.end) else { return nil }
            if b <= a { b += 1440 }
            if a < 360 { a += 1440; b += 1440 }  // 00:00~02:00처럼 따로 적은 심야
            return (s, a, b)
        }
    }

    /// 하강 시작 시각으로 세션을 정한다. nil = 세션을 나누지 않음(시간표 없음·오래됨).
    static func session(at t: Date, resortId: String, timetables: [Timetable]) -> SessionKind? {
        guard let d = pick(t, resortId: resortId, timetables: timetables) else { return nil }
        // 지난 시즌이 끝나기(5월 1일 06:00) 전에 고친 시간표는 이번 시즌용이 아니라 오래된 것으로 본다.
        // 개장 전(5~10월)에 입력한 시간표는 이번 시즌용이다(decisions 2026-11-08).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        guard let season = d.season, let y = Int(season.prefix(4)),
              let freshFrom = cal.date(from: DateComponents(year: y, month: 5, day: 1, hour: 6)),
              d.timetable.updatedAt >= freshFrom else { return nil }

        let m = Int(t.timeIntervalSince(d.midnight) / 60)
        for (s, a, b) in spans(d) where a <= m && m < b {
            return SessionKind(rawValue: s.kind.rawValue)
        }
        return .unclassified
    }

    /// 오늘 운영 구간 (R34·R35). 영업일을 덮는 최신 시간표가 이번 시즌으로 확인됐을 때만 돌려준다.
    /// nil = 미확인(시간표 없음, verifiedSeason 없음·지난 시즌, 비시즌). 빈 배열 = 확인됐지만 그날 요일 구간 없음.
    static func today(resortId: String, now: Date, timetables: [Timetable]) -> [Open]? {
        guard let d = pick(now, resortId: resortId, timetables: timetables),
              let season = d.season, d.timetable.verifiedSeason == season else { return nil }
        return spans(d).map { s, a, b in
            Open(kind: s.kind, start: s.start, end: s.end,
                 interval: DateInterval(start: d.midnight.addingTimeInterval(Double(a * 60)),
                                        end: d.midnight.addingTimeInterval(Double(b * 60))),
                 nextDay: b > 1440 || (b == 1440 && s.end != "24:00"))  // "00:00" 끝은 다음 날 0시, "24:00"은 그날 끝
        }
        .sorted { $0.interval.start < $1.interval.start }
    }

    /// 오늘 운영 구간 하나. nextDay: 적힌 시작·끝 시각이 영업일 날짜의 다음 날("심야 · 다음 날", 22:00–00:00 포함, 18:00–24:00은 아님)
    struct Open: Equatable {
        var kind: Session.Kind
        var start: String
        var end: String
        var interval: DateInterval
        var nextDay: Bool
    }

    private static func minutes(_ s: String) -> Int? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : nil
    }
}

nonisolated enum SessionKind: String { case day, night, lateNight, unclassified }
