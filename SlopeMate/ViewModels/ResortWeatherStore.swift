import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ResortWeatherStore {
    private(set) var weatherByResort: [UUID: WeatherDisplayModel] = [:]
    private(set) var isLoading = false
    var alertMessage: String?

    @ObservationIgnored
    private let service: WeatherServicing
    
    @ObservationIgnored
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        return cal
    }()

    init(service: WeatherServicing = WeatherService()) {
        self.service = service
    }

    func loadWeather(for resorts: [Resort], on date: Date) async {
        guard !resorts.isEmpty else {
            weatherByResort = [:]
            return
        }

        isLoading = true
        alertMessage = nil

        let today = calendar.startOfDay(for: Date())
        let selectedDay = calendar.startOfDay(for: date)
        let daysDiff = calendar.dateComponents([.day], from: today, to: selectedDay).day ?? 0

        var snapshot: [UUID: WeatherDisplayModel] = [:]
        var encounteredError: Error?
        let client = service

        await withTaskGroup(of: (UUID, Result<WeatherDisplayModel, Error>).self) { group in
            for resort in resorts {
                group.addTask {
                    do {
                        if daysDiff == 0 {
                            // 오늘: One Call API의 current 사용 (daily[0]에서 일출/일몰 정보 가져오기)
                            let oneCall = try await client.fetchOneCall(
                                latitude: resort.latitude,
                                longitude: resort.longitude
                            )
                            return (resort.id, .success(WeatherDisplayModel(
                                current: oneCall.current,
                                todayDaily: oneCall.daily.first,
                                cityName: resort.name
                            )))
                        } else if daysDiff > 0 && daysDiff <= 7 {
                            // 미래 1-7일: One Call API의 daily 배열에서 찾기
                            let oneCall = try await client.fetchOneCall(
                                latitude: resort.latitude,
                                longitude: resort.longitude
                            )
                            
                            // 선택한 날짜의 일별 예보 찾기
                            let targetDate = selectedDay
                            if let dailyForecast = oneCall.daily.first(where: { daily in
                                let forecastDate = Date(timeIntervalSince1970: daily.dt)
                                let forecastDay = self.calendar.startOfDay(for: forecastDate)
                                return forecastDay == targetDate
                            }) {
                                return (resort.id, .success(WeatherDisplayModel(
                                    daily: dailyForecast,
                                    cityName: resort.name
                                )))
                            } else {
                                return (resort.id, .failure(WeatherServiceError.noDataAvailable))
                            }
                        } else if daysDiff < 0 {
                            // 과거 날짜는 지원하지 않음
                            return (resort.id, .failure(WeatherServiceError.noDataAvailable))
                        } else if daysDiff > 7 {
                            // 7일 이후는 예보 범위를 벗어남
                            return (resort.id, .failure(WeatherServiceError.noDataAvailable))
                        } else {
                            return (resort.id, .failure(WeatherServiceError.noDataAvailable))
                        }
                    } catch {
                        return (resort.id, .failure(error))
                    }
                }
            }

            for await (resortID, result) in group {
                switch result {
                case .success(let weather):
                    snapshot[resortID] = weather
                case .failure(let error):
                    encounteredError = error
                }
            }
        }

        weatherByResort = snapshot
        isLoading = false

        if let error = encounteredError {
            alertMessage = error.localizedDescription
        }
    }
}

