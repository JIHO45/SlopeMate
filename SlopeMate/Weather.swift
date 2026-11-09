import CoreLocation
import Foundation
import WeatherKit

/// 리조트 날씨 (R33). WeatherKit 결과를 화면이 쓰는 값으로 바꾼 것. 단위는 °C, m/s, cm, 0~1.
nonisolated struct WeatherSnapshot {
    struct Current {
        var temperature: Double
        var symbolName: String
        var condition: String        // WeatherCondition.description
        var windSpeed: Double
        var humidity: Double
    }
    struct Hour {
        var date: Date               // 시간대 시작
        var temperature: Double
        var symbolName: String
        var precipitationChance: Double
        var windSpeed: Double
        var humidity: Double
        var snowfall: Double?        // iOS 18 이상만
    }
    struct Day {
        var date: Date
        var high: Double
        var low: Double
        var symbolName: String
        var precipitationChance: Double
    }
    struct Attribution {
        var markLightURL: URL
        var markDarkURL: URL
        var legalPageURL: URL
    }

    var fetchedAt: Date
    var current: Current
    var hours: [Hour]                // 어제 12:00 ~ 조회 끝. 예상 설질이 지난 값을 쓴다
    var days: [Day]                  // 7일
    var attribution: Attribution

    /// 화면용: 지금 시간대부터 24시간.
    func next24h(now: Date) -> [Hour] {
        Array(hours.filter { $0.date > now.addingTimeInterval(-3600) }.prefix(24))
    }
}

nonisolated enum Weather {
    static let maxAge: TimeInterval = 30 * 60

    /// 시간별 조회 범위: 어제 영업일 12:00 ~ max(내일 영업일 06:00, 지금+24시간).
    static func hourlyRange(now: Date) -> (start: Date, end: Date) {
        let today = BusinessDay.start(of: now)
        return (today.addingTimeInterval(-18 * 3600), max(BusinessDay.end(of: now), now.addingTimeInterval(24 * 3600)))
    }

    /// WeatherKit 한 번 호출. 엔타이틀먼트가 있어야 동작한다(기기 확인).
    static func fetch(resort: Resort, now: Date) async throws -> WeatherSnapshot {
        let service = WeatherService.shared
        let range = hourlyRange(now: now)
        let (cur, hourly, daily) = try await service.weather(
            for: CLLocation(latitude: resort.latitude, longitude: resort.longitude),
            including: .current, .hourly(startDate: range.start, endDate: range.end), .daily)
        let attr = try await service.attribution

        func c(_ m: Measurement<UnitTemperature>) -> Double { m.converted(to: .celsius).value }
        func ms(_ w: Wind) -> Double { w.speed.converted(to: .metersPerSecond).value }

        return WeatherSnapshot(
            fetchedAt: now,
            current: .init(temperature: c(cur.temperature), symbolName: cur.symbolName,
                           condition: cur.condition.description, windSpeed: ms(cur.wind), humidity: cur.humidity),
            hours: hourly.map { h in
                var snow: Double?
                if #available(iOS 18.0, *) { snow = h.snowfallAmount.converted(to: .centimeters).value }
                return .init(date: h.date, temperature: c(h.temperature), symbolName: h.symbolName,
                             precipitationChance: h.precipitationChance, windSpeed: ms(h.wind),
                             humidity: h.humidity, snowfall: snow)
            },
            days: daily.prefix(7).map {
                .init(date: $0.date, high: c($0.highTemperature), low: c($0.lowTemperature),
                      symbolName: $0.symbolName, precipitationChance: $0.precipitationChance)
            },
            attribution: .init(markLightURL: attr.combinedMarkLightURL, markDarkURL: attr.combinedMarkDarkURL,
                               legalPageURL: attr.legalPageURL))
    }
}

/// 리조트별 메모리 캐시. 30분 지나면 다시 조회한다. 디스크에는 두지 않는다.
@MainActor final class WeatherCache {
    typealias Fetch = (Resort, Date) async throws -> WeatherSnapshot

    private let fetch: Fetch
    private let now: () -> Date
    private var snapshots: [String: WeatherSnapshot] = [:]

    init(fetch: @escaping Fetch = { try await Weather.fetch(resort: $0, now: $1) }, now: @escaping () -> Date = { Date() }) {
        self.fetch = fetch
        self.now = now
    }

    /// 30분 안 캐시는 조회 없이 돌려준다. 그래서 조회가 실패하면 쓸 캐시가 없고 오류를 던진다.
    func weather(for resort: Resort) async throws -> WeatherSnapshot {
        let t = now()
        let cached = snapshots[resort.id].flatMap { t.timeIntervalSince($0.fetchedAt) < Weather.maxAge ? $0 : nil }
        if let cached { return cached }
        let s = try await fetch(resort, t)
        snapshots[resort.id] = s
        return s
    }
}
