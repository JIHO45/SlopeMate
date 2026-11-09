import Foundation
import Testing
@testable import SlopeMate

struct SnowForecastTests {
    let f = ISO8601DateFormatter()
    func at(_ s: String) -> Date { f.date(from: s + "+09:00")! }
    var day: Date { at("2026-12-10T06:00:00") }  // 오늘 영업일 시작
    var noon: Date { at("2026-12-10T10:00:00") }

    /// 어제 12:00 ~ 내일 06:00 시간별. 구간마다 같은 값
    func hours(yHigh: Double = 0, nLow: Double = -4, tHigh: Double = 1, humidity: Double = 0.5,
               wind: Double = 3, snow: Double? = nil) -> [WeatherSnapshot.Hour] {
        (-18..<24).map { i in
            let temp: Double = switch i {
            case -18 ..< -12: yHigh
            case -12 ..< 0: nLow
            case 3 ..< 10: tHigh
            default: tHigh - 5
            }
            return WeatherSnapshot.Hour(date: day.addingTimeInterval(Double(i) * 3600), temperature: temp,
                                        symbolName: "cloud", precipitationChance: 0, windSpeed: wind,
                                        humidity: humidity, snowfall: (-12 ..< 0).contains(i) ? snow : nil)
        }
    }

    func est(_ h: [WeatherSnapshot.Hour], now: Date? = nil) -> (SnowForecast.Level, String)? {
        SnowForecast.estimate(hours: h, now: now ?? noon).map { ($0.level, $0.reason) }
    }

    @Test func slush() {
        #expect(est(hours(tHigh: 7))! == (.slush, "낮 최고 7도"))
        #expect(est(hours(tHigh: 3.4, humidity: 0.85))! == (.slush, "낮 최고 3도"))
        #expect(est(hours(tHigh: 3.4, humidity: 0.7))!.0 == .good)
        // 슬러시가 아이스보다 먼저
        #expect(est(hours(yHigh: 5, nLow: -8, tHigh: 6))!.0 == .slush)
    }

    @Test func ice() {
        #expect(est(hours(yHigh: 3, nLow: -8, tHigh: 0))! == (.ice, "어제 낮 최고 3도, 밤사이 영하 8도"))
        #expect(est(hours(yHigh: 1.4, nLow: -8, tHigh: 0))!.0 == .firm)  // 어제 녹지 않음
    }

    @Test func firm() {
        #expect(est(hours(nLow: -10))! == (.firm, "밤사이 영하 10도"))
        #expect(est(hours(wind: 12))! == (.firm, "바람 초속 12m"))
        #expect(est(hours(nLow: -9, wind: 10))! == (.firm, "밤사이 영하 9도, 바람 초속 10m"))
    }

    @Test func goodWithSnow() {
        #expect(est(hours())! == (.good, "밤사이 영하 4도, 낮 최고 1도"))
        #expect(est(hours(snow: 0.25))! == (.good, "밤사이 영하 4도, 낮 최고 1도, 밤사이 눈 3cm"))  // 12시간 합
        #expect(est(hours(snow: 0.05))!.1 == "밤사이 영하 4도, 낮 최고 1도")  // 1cm 미만은 적지 않음
        #expect(est(hours(nLow: -10, snow: 0.5))!.1 == "밤사이 영하 10도, 밤사이 눈 6cm")
    }

    @Test func missingHourIsNil() {
        #expect(est([]) == nil)
        var h = hours()
        h.remove(at: 10)  // 밤사이 한 시간 빠짐
        #expect(est(h) == nil)
        h = hours()
        h.removeLast(13)  // 오늘 17시부터 빠짐: 바람(06~18시) 부족
        #expect(est(h) == nil)
        #expect(est(Array(hours().dropLast(12)))! == (.good, "밤사이 영하 4도, 낮 최고 1도"))  // 18시 이후는 없어도 됨
    }

    /// 새벽 2시는 전날 영업일: 오늘 낮 = 전날 09~16시
    @Test func businessDayBoundary() {
        let h = hours(yHigh: 3, nLow: -8, tHigh: 0)
        #expect(est(h, now: at("2026-12-11T02:00:00"))! == (.ice, "어제 낮 최고 3도, 밤사이 영하 8도"))
        #expect(est(h, now: at("2026-12-10T05:59:00")) == nil)  // 그 전 영업일: 그 전날 값 없음
        #expect(est(h, now: at("2026-12-11T06:00:00")) == nil)  // 다음 영업일: 내일 낮 값 없음
    }

    @Test func rounding() {
        #expect(SnowForecast.deg(-0.4) == "0도")
        #expect(SnowForecast.deg(-2.5) == "영하 3도")
        #expect(SnowForecast.deg(2.5) == "3도")
    }
}
