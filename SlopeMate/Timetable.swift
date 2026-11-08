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

    static let all: [Timetable] = {
        let url = Bundle.main.url(forResource: "timetables", withExtension: "json")!
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try! d.decode([Timetable].self, from: Data(contentsOf: url))
    }()

    /// 하강 시작 시각으로 세션을 정한다. nil = 세션을 나누지 않음(시간표 없음·오래됨).
    static func session(at t: Date, resortId: String, timetables: [Timetable]) -> SessionKind? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let day = BusinessDay.start(of: t)
        let midnight = day.addingTimeInterval(-6 * 3600)
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: day)
        let date = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)

        // 문자열 비교로 충분하다(yyyy-MM-dd)
        guard let tt = timetables
            .filter({ $0.resortId == resortId && $0.validFrom <= date && date <= $0.validTo })
            .max(by: { $0.version < $1.version }) else { return nil }

        // 지난 시즌이 끝나기(5월 1일 06:00) 전에 고친 시간표는 이번 시즌용이 아니라 오래된 것으로 본다.
        // 개장 전(5~10월)에 입력한 시간표는 이번 시즌용이다(decisions 2026-11-08).
        guard let season = Stats.season(of: day), let y = Int(season.prefix(4)),
              let freshFrom = cal.date(from: DateComponents(year: y, month: 5, day: 1, hour: 6)),
              tt.updatedAt >= freshFrom else { return nil }

        // 영업일 0시부터 분. 새벽 1시는 25:00(1500분)
        let m = Int(t.timeIntervalSince(midnight) / 60)
        for s in tt.sessions {
            if let w = s.weekdays, !w.contains(c.weekday!) { continue }
            guard var a = minutes(s.start), var b = minutes(s.end) else { continue }
            if b <= a { b += 1440 }
            if a < 360 { a += 1440; b += 1440 }  // 00:00~02:00처럼 따로 적은 심야
            if a <= m && m < b { return SessionKind(rawValue: s.kind.rawValue) }
        }
        return .unclassified
    }

    private static func minutes(_ s: String) -> Int? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : nil
    }
}

nonisolated enum SessionKind: String { case day, night, lateNight, unclassified }
