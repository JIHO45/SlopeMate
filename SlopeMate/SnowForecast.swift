import Foundation

/// 예상 설질 첫 규칙 (R39). 시간별 날씨로 오늘 영업일의 설질을 짐작한다.
nonisolated enum SnowForecast {
    enum Level: String {
        case ice, firm, good, slush
        var label: String {
            switch self {
            case .ice: "아이스"
            case .firm: "단단함"
            case .good: "적당함"
            case .slush: "슬러시"
            }
        }
    }

    /// 기준값. 사용자 평가가 쌓이면 보정한다.
    struct Params {
        var slushHigh = 6.0           // 오늘 낮 최고
        var slushWarmHigh = 3.0       // 이 기온 이상이고
        var slushHumidity = 0.8       // 습도가 이 이상이면 슬러시
        var iceYesterdayHigh = 2.0    // 어제 낮에 녹고
        var iceNightLow = -3.0        // 밤사이 얼면 아이스
        var firmNightLow = -8.0
        var firmWind = 10.0           // m/s
        var snowMention = 1.0         // cm, 이 이상이면 근거에 적음
    }

    /// 한국 시간 기준. "오늘" = now가 속한 영업일. 필요한 시간대 값이 하나라도 없으면 nil.
    static func estimate(hours: [WeatherSnapshot.Hour], now: Date, params p: Params = .init()) -> (level: Level, reason: String)? {
        let day = BusinessDay.start(of: now)  // 오늘 06:00
        // 영업일 시작부터 시간 단위 [from, to). 시간대가 하나라도 빠지면 nil
        func window(_ from: Int, _ to: Int) -> [WeatherSnapshot.Hour]? {
            let a = day.addingTimeInterval(Double(from) * 3600), b = day.addingTimeInterval(Double(to) * 3600)
            let w = hours.filter { $0.date >= a && $0.date < b }
            return w.count == to - from ? w : nil
        }
        guard let yesterday = window(-18, -12),  // 어제 12~18시
              let night = window(-12, 0),        // 어제 18시 ~ 오늘 06시
              let today = window(3, 10),         // 오늘 09~16시
              let windHours = window(0, 12)      // 오늘 06~18시
        else { return nil }

        let yHigh = yesterday.map(\.temperature).max()!
        let nLow = night.map(\.temperature).min()!
        let tHigh = today.map(\.temperature).max()!
        let humidity = today.map(\.humidity).reduce(0, +) / Double(today.count)
        let wind = windHours.map(\.windSpeed).max()!
        let snow = night.compactMap(\.snowfall).reduce(0, +)  // 적설 없으면 0

        let level: Level
        var reason: [String]
        if tHigh >= p.slushHigh || (tHigh >= p.slushWarmHigh && humidity >= p.slushHumidity) {
            (level, reason) = (.slush, ["낮 최고 \(deg(tHigh))"])
        } else if yHigh >= p.iceYesterdayHigh && nLow <= p.iceNightLow {
            (level, reason) = (.ice, ["어제 낮 최고 \(deg(yHigh))", "밤사이 \(deg(nLow))"])
        } else if nLow <= p.firmNightLow || wind >= p.firmWind {
            level = .firm
            reason = []
            if nLow <= p.firmNightLow { reason.append("밤사이 \(deg(nLow))") }
            if wind >= p.firmWind { reason.append("바람 초속 \(Int(wind.rounded()))m") }
        } else {
            (level, reason) = (.good, ["밤사이 \(deg(nLow))", "낮 최고 \(deg(tHigh))"])
        }
        if snow >= p.snowMention { reason.append("밤사이 눈 \(Int(snow.rounded()))cm") }
        return (level, reason.joined(separator: ", "))
    }

    /// 반올림 정수. 영하는 "영하 N도"
    static func deg(_ c: Double) -> String {
        let n = Int(c.rounded())
        return n < 0 ? "영하 \(-n)도" : "\(n)도"
    }
}
