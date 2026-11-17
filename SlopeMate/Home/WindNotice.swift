import Foundation

/// 강풍 안내 (R35). 바람 강조와 공식 현황 연결까지만 하고, 리프트 운휴는 예측하지 않는다.
nonisolated struct WindNotice: Equatable {
    enum Scope: Equatable { case remainingHours, next24h }

    /// 화면 강조용 내부 기준. 안전·운휴 판단 기준이 아니다.
    static let threshold = 10.0   // m/s

    var maxSpeed: Double
    var scope: Scope

    /// today: 확인된 오늘 운영 구간(Timetable.today). nil이면 미확인 → 지금부터 24시간.
    /// 확인됐는데 남은 운영 구간이 없으면(요일 구간 없음, 운영 끝) 안내하지 않는다.
    /// 1시간 예보는 [시작, 시작+1시간)이 대상 구간과 조금이라도 겹치면 포함한다.
    /// 포함된 예보가 없으면 nil(강풍 없음으로 보지 않음).
    static func evaluate(hours: [WeatherSnapshot.Hour], now: Date, today: [Timetable.Open]?) -> WindNotice? {
        let windows: [DateInterval]
        let scope: Scope
        if let today {
            windows = today.compactMap { o in
                let start = max(now, o.interval.start)
                return start < o.interval.end ? DateInterval(start: start, end: o.interval.end) : nil
            }
            scope = .remainingHours
        } else {
            windows = [DateInterval(start: now, duration: 24 * 3600)]
            scope = .next24h
        }
        let speeds = hours.filter { h in
            windows.contains { $0.start < h.date.addingTimeInterval(3600) && h.date < $0.end }
        }.map(\.windSpeed)
        guard let top = speeds.max(), top >= threshold else { return nil }
        return WindNotice(maxSpeed: top, scope: scope)
    }

    var title: String {
        "바람 최대 \(Int(maxSpeed.rounded()))m/s · \(scope == .remainingHours ? "남은 운영 시간" : "향후 24시간 예보")"
    }
    static let hint = "리프트 운행은 공식 현황에서 확인하세요"
}
