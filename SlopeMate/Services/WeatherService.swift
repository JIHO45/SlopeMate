import Foundation

protocol WeatherServicing {
    func fetchOneCall(latitude: Double, longitude: Double) async throws -> OneCallResponse
    func fetchHistoricalWeather(latitude: Double, longitude: Double, date: Date) async throws -> HistoricalWeatherResponse
}

enum WeatherServiceError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case httpError(Int)
    case noDataAvailable
    case subscriptionRequired

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenWeatherMap API 키가 설정되어 있지 않습니다."
        case .invalidURL:
            return "잘못된 요청입니다."
        case .httpError(let code):
            return "날씨 정보를 불러오지 못했습니다. (HTTP \(code))"
        case .noDataAvailable:
            return "해당 날짜의 날씨 정보가 없습니다."
        case .subscriptionRequired:
            return "One Call API 3.0 구독이 필요합니다."
        }
    }
}

struct WeatherService: WeatherServicing {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let apiKey: String

    init(
        session: URLSession = .shared,
        decoder: JSONDecoder = WeatherService.makeDecoder(),
        apiKey: String? = nil
    ) {
        self.session = session
        self.decoder = decoder
        self.apiKey = WeatherService.resolveAPIKey(override: apiKey)
    }

    // One Call API 3.0 - 현재 + 미래 예보 (8일)
    func fetchOneCall(latitude: Double, longitude: Double) async throws -> OneCallResponse {
        guard !apiKey.isEmpty else { throw WeatherServiceError.missingAPIKey }
        guard var components = URLComponents(string: "https://api.openweathermap.org/data/3.0/onecall") else {
            throw WeatherServiceError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "lat", value: "\(latitude)"),
            URLQueryItem(name: "lon", value: "\(longitude)"),
            URLQueryItem(name: "exclude", value: "minutely,hourly"),
            URLQueryItem(name: "appid", value: apiKey),
            URLQueryItem(name: "units", value: "metric"),
            URLQueryItem(name: "lang", value: "kr")
        ]

        guard let url = components.url else { throw WeatherServiceError.invalidURL }

        let (data, response) = try await session.data(from: url)

        guard
            let httpResponse = response as? HTTPURLResponse,
            200..<300 ~= httpResponse.statusCode
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            
            #if DEBUG
            if let errorString = String(data: data, encoding: .utf8) {
                print("❌ One Call API 에러 응답 (HTTP \(statusCode)): \(errorString)")
            }
            #endif
            
            if statusCode == 401 {
                // 401 에러 응답 메시지 확인
                if let errorString = String(data: data, encoding: .utf8),
                   errorString.contains("Invalid API key") {
                    throw WeatherServiceError.missingAPIKey
                }
                throw WeatherServiceError.subscriptionRequired
            }
            throw WeatherServiceError.httpError(statusCode)
        }

        return try decoder.decode(OneCallResponse.self, from: data)
    }
    
    // 과거 날씨 (One Call History API)
    func fetchHistoricalWeather(latitude: Double, longitude: Double, date: Date) async throws -> HistoricalWeatherResponse {
        guard !apiKey.isEmpty else { throw WeatherServiceError.missingAPIKey }
        
        let timestamp = Int(date.timeIntervalSince1970)
        guard var components = URLComponents(string: "https://api.openweathermap.org/data/3.0/onecall/timemachine") else {
            throw WeatherServiceError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "lat", value: "\(latitude)"),
            URLQueryItem(name: "lon", value: "\(longitude)"),
            URLQueryItem(name: "dt", value: "\(timestamp)"),
            URLQueryItem(name: "appid", value: apiKey),
            URLQueryItem(name: "units", value: "metric"),
            URLQueryItem(name: "lang", value: "kr")
        ]

        guard let url = components.url else { throw WeatherServiceError.invalidURL }

        let (data, response) = try await session.data(from: url)

        guard
            let httpResponse = response as? HTTPURLResponse,
            200..<300 ~= httpResponse.statusCode
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            
            #if DEBUG
            if let errorString = String(data: data, encoding: .utf8) {
                print("❌ Historical API 에러 응답 (HTTP \(statusCode)): \(errorString)")
            }
            #endif
            
            if statusCode == 401 {
                if let errorString = String(data: data, encoding: .utf8),
                   errorString.contains("Invalid API key") {
                    throw WeatherServiceError.missingAPIKey
                }
                throw WeatherServiceError.subscriptionRequired
            }
            throw WeatherServiceError.httpError(statusCode)
        }

        return try decoder.decode(HistoricalWeatherResponse.self, from: data)
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func resolveAPIKey(override: String?) -> String {
        if let override, !override.isEmpty {
            return override
        }

        if let infoKey = Bundle.main.object(forInfoDictionaryKey: "OPEN_WEATHER_API_KEY") as? String,
           !infoKey.isEmpty {
            return infoKey
        }

        if let envKey = ProcessInfo.processInfo.environment["OPEN_WEATHER_API_KEY"],
           !envKey.isEmpty {
            return envKey
        }

        return ""
    }
}

