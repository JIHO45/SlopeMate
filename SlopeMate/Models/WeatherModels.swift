import Foundation
import SwiftUI

// MARK: - One Call API 3.0 Response
struct OneCallResponse: Decodable {
    let current: CurrentWeather
    let daily: [DailyForecast]
    
    struct CurrentWeather: Decodable {
        let dt: TimeInterval
        let temp: Double
        let feelsLike: Double
        let humidity: Int
        let windSpeed: Double
        let weather: [WeatherCondition]
    }
    
    struct DailyForecast: Decodable {
        let dt: TimeInterval
        let temp: Temperature
        let feelsLike: FeelsLike
        let humidity: Int
        let windSpeed: Double
        let weather: [WeatherCondition]
        let sunrise: TimeInterval
        let sunset: TimeInterval
    }
    
    struct Temperature: Decodable {
        let day: Double
        let min: Double
        let max: Double
    }
    
    struct FeelsLike: Decodable {
        let day: Double
    }
    
    struct WeatherCondition: Decodable {
        let description: String
        let icon: String
    }
}

// MARK: - Historical Weather Response
struct HistoricalWeatherResponse: Decodable {
    let data: [HistoricalData]
    
    struct HistoricalData: Decodable {
        let dt: TimeInterval
        let temp: Double
        let feelsLike: Double
        let humidity: Int
        let windSpeed: Double
        let weather: [WeatherCondition]
    }
    
    struct WeatherCondition: Decodable {
        let description: String
        let icon: String
    }
}

struct WeatherDisplayModel: Identifiable, Hashable {
    let id = UUID()
    let temperature: Double
    let description: String
    let iconCode: String
    let windSpeed: Double
    let humidity: Int
    let feelsLike: Double
    let sunrise: Date
    let sunset: Date
    let cityName: String
    let timestamp: Date

    var iconURL: URL? {
        guard !iconCode.isEmpty else { return nil }
        // One Call API 3.0은 아이콘 코드가 "01d", "01n" 형식
        return URL(string: "https://openweathermap.org/img/wn/\(iconCode)@2x.png")
    }
    
    /// SF Symbol 이름 반환 (모던한 애플 아이콘)
    var systemIconName: String {
        // iconCode 기반 매핑 (더 정확)
        let code = iconCode.prefix(2) // "01d" -> "01"
        
        switch code {
        // 맑음
        case "01":
            return "sun.max.fill"
        
        // 약간 흐림
        case "02":
            return "cloud.sun.fill"
        
        // 흐림
        case "03", "04":
            return "cloud.fill"
        
        // 비
        case "09", "10":
            return "cloud.rain.fill"
        
        // 천둥번개
        case "11":
            return "cloud.bolt.fill"
        
        // 눈
        case "13":
            return "cloud.snow.fill"
        
        // 안개
        case "50":
            return "cloud.fog.fill"
        
        default:
            // description 기반 폴백
            let desc = description.lowercased()
            if desc.contains("맑음") || desc.contains("청명") {
                return "sun.max.fill"
            } else if desc.contains("구름") {
                return "cloud.fill"
            } else if desc.contains("비") {
                return "cloud.rain.fill"
            } else if desc.contains("눈") {
                return "cloud.snow.fill"
            } else if desc.contains("천둥") {
                return "cloud.bolt.fill"
            } else if desc.contains("안개") {
                return "cloud.fog.fill"
            } else {
                return "cloud.sun.fill"
            }
        }
    }
    
    /// 아이콘 색상 (온도 기반)
    var iconColor: Color {
        switch temperature {
        case ..<(-10):
            return .purple
        case -10..<0:
            return .blue
        case 0..<10:
            return .cyan
        case 10..<20:
            return .green
        case 20..<30:
            return .orange
        default:
            return .red
        }
    }
}

extension WeatherDisplayModel {
    private static let seoulTimeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
    
    // One Call API - 현재 날씨 (daily[0]에서 일출/일몰 정보 가져오기)
    init(current: OneCallResponse.CurrentWeather, todayDaily: OneCallResponse.DailyForecast?, cityName: String) {
        self.temperature = current.temp
        let rawDescription = current.weather.first?.description ?? "정보 없음"
        self.description = Self.translateDescription(rawDescription)
        // 현재 시간에 맞는 아이콘 사용 (API가 반환한 아이콘)
        self.iconCode = current.weather.first?.icon ?? "01d"
        self.windSpeed = current.windSpeed
        self.humidity = current.humidity
        self.feelsLike = current.feelsLike
        // daily[0]에서 일출/일몰 정보 가져오기 (한국 시간대)
        if let todayDaily {
            self.sunrise = Date(timeIntervalSince1970: todayDaily.sunrise)
            self.sunset = Date(timeIntervalSince1970: todayDaily.sunset)
        } else {
            self.sunrise = Date()
            self.sunset = Date()
        }
        self.cityName = cityName
        // UTC 시간을 한국 시간대로 변환
        self.timestamp = Date(timeIntervalSince1970: current.dt)
    }
    
    // One Call API - 일별 예보
    init(daily: OneCallResponse.DailyForecast, cityName: String) {
        self.temperature = daily.temp.day
        let rawDescription = daily.weather.first?.description ?? "정보 없음"
        self.description = Self.translateDescription(rawDescription)
        self.iconCode = daily.weather.first?.icon ?? "01d"
        self.windSpeed = daily.windSpeed
        self.humidity = daily.humidity
        self.feelsLike = daily.feelsLike.day
        // 한국 시간대 적용
        self.sunrise = Date(timeIntervalSince1970: daily.sunrise)
        self.sunset = Date(timeIntervalSince1970: daily.sunset)
        self.cityName = cityName
        self.timestamp = Date(timeIntervalSince1970: daily.dt)
    }
    
    // 과거 날씨
    init(historical: HistoricalWeatherResponse.HistoricalData, cityName: String) {
        self.temperature = historical.temp
        let rawDescription = historical.weather.first?.description ?? "정보 없음"
        self.description = Self.translateDescription(rawDescription)
        self.iconCode = historical.weather.first?.icon ?? "01d"
        self.windSpeed = historical.windSpeed
        self.humidity = historical.humidity
        self.feelsLike = historical.feelsLike
        // 과거 날씨는 일출/일몰 정보가 없으므로 기본값
        self.sunrise = Date()
        self.sunset = Date()
        self.cityName = cityName
        self.timestamp = Date(timeIntervalSince1970: historical.dt)
    }

    private static func translateDescription(_ raw: String) -> String {
        let mapping: [String: String] = [
            // 맑음 계열
            "맑음": "맑음",
            "청명함": "맑음",
            
            // 구름 계열
            "약간의 구름이 낀 하늘": "구름 조금",
            "한 조각 구름이 낀 하늘": "구름 조금",
            "튼구름": "구름 많음",
            "온흐림": "흐림",
            "구름많음": "구름 많음",
            "구름조금": "구름 조금",
            
            // 비 계열
            "가벼운 비": "약한 비",
            "보통 비": "비",
            "강한 비": "폭우",
            "매우 강한 비": "폭우",
            "극심한 비": "폭우",
            "소나기": "소나기",
            "약한 소나기 비": "약한 소나기",
            "소나기 비": "소나기",
            "강한 소나기 비": "강한 소나기",
            
            // 눈 계열
            "가벼운 눈": "약한 눈",
            "눈": "눈",
            "강한 눈": "폭설",
            "진눈깨비": "진눈깨비",
            "약한 눈보라": "눈보라",
            "눈보라": "눈보라",
            
            // 안개/연무 계열
            "박무": "옅은 안개",
            "안개": "안개",
            "연무": "연무",
            
            // 기타
            "뇌우": "천둥번개",
            "실 비": "이슬비",
            "우박": "우박"
        ]
        return mapping[raw] ?? raw
    }
}

#if DEBUG
extension WeatherDisplayModel {
    static var preview: WeatherDisplayModel {
        WeatherDisplayModel(
            temperature: -3.2,
            description: "눈",
            iconCode: "13d",
            windSpeed: 12.4,
            humidity: 78,
            feelsLike: -8.0,
            sunrise: Date().addingTimeInterval(-3600 * 6),
            sunset: Date().addingTimeInterval(3600 * 6),
            cityName: "Preview",
            timestamp: Date()
        )
    }
}
#endif

