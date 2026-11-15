import Foundation

/// 시뮬레이터에서 만들 수 없는 실패를 재현하는 실행 인자 (DEBUG 빌드만). 출시 빌드에서는 항상 꺼져 있다.
/// - `-SMFailSave`: 기록 중 위치점 저장이 실패한다(실제 저장 실패 처리 경로를 탄다)
/// - `-SMFailWeather`: "다시 시도"를 누르기 전까지 날씨 조회가 실패한다
/// - `-SMFailVideoOnce`: 첫 동영상 만들기만 만드는 중 화면을 띄운 뒤 실패한다
/// - `-SMBanner battery|weak`: 배터리 12%(충전 안 함) 또는 약한 위치 신호를 실제 배너 조건에 넣는다
/// - `-SMDeleteSheet confirm|done|failed`: 계정 삭제 시트를 그 상태로 띄운다(시뮬레이터는 Apple 로그인이 안 됨)
/// - `-SMDemoWeather`: WeatherKit 대신 고정된 겨울 날씨를 쓴다(App Store 스크린샷용, SlopeMateScreenShot/ko/src)
nonisolated enum DebugFailures {
    struct Injected: LocalizedError { var errorDescription: String? { "디버그 실패 주입" } }

    static func on(_ flag: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(flag)
        #else
        false
        #endif
    }

    private static var banner: String? {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "-SMBanner").flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil }
        #else
        nil
        #endif
    }

    static var deleteSheet: String? {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "-SMDeleteSheet").flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil }
        #else
        nil
        #endif
    }

    /// 배터리 잔량 대신 쓸 값(충전 안 함으로 본다)
    static var batteryLevel: Float? { banner == "battery" ? 0.12 : nil }
    /// 마지막 위치점의 정확도를 기준보다 나쁘게 본다
    static var weakSignal: Bool { banner == "weak" }

    /// 날씨 조회 실패 중인지. 홈의 "다시 시도"가 끈다.
    nonisolated(unsafe) static var weatherFails = on("-SMFailWeather")

    /// 한 번만 실패시킨다
    nonisolated(unsafe) private static var used: Set<String> = []
    static func once(_ flag: String) -> Bool {
        guard on(flag), !used.contains(flag) else { return false }
        used.insert(flag)
        return true
    }

    /// `-SMDemoWeather`: 어제 12시부터 48시간, 영하권 맑음
    static func demoWeather(_ now: Date) -> WeatherSnapshot? {
        guard on("-SMDemoWeather") else { return nil }
        let from = BusinessDay.start(of: now).addingTimeInterval(-18 * 3600)
        let hours = (0..<48).map { i -> WeatherSnapshot.Hour in
            let h = (i + 12) % 24, temp = -7 + 6 * max(0, sin(Double(h - 8) / 10 * .pi))
            return .init(date: from.addingTimeInterval(Double(i) * 3600), temperature: temp, symbolName: "sun.max",
                         precipitationChance: 0.1, windSpeed: 3, humidity: 0.5, snowfall: i > 8 && i < 14 ? 0.6 : 0)
        }
        let url = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!
        return WeatherSnapshot(
            fetchedAt: now, current: .init(temperature: -4, symbolName: "sun.max", condition: "맑음", windSpeed: 3, humidity: 0.5),
            hours: hours,
            days: [(-1, -9, "sun.max", 0.1), (-3, -11, "cloud.sun", 0.2), (-5, -12, "cloud.snow", 0.7), (-6, -14, "snowflake", 0.6),
                   (-2, -10, "sun.max", 0.1), (0, -8, "cloud.sun", 0.2), (1, -7, "cloud", 0.3)].enumerated().map { i, d in
                .init(date: BusinessDay.start(of: now).addingTimeInterval(Double(i) * 86400), high: Double(d.0), low: Double(d.1),
                      symbolName: d.2, precipitationChance: d.3) },
            attribution: .init(markLightURL: url, markDarkURL: url, legalPageURL: url))
    }
}
