import Foundation

/// 시뮬레이터에서 만들 수 없는 실패를 재현하는 실행 인자 (DEBUG 빌드만). 출시 빌드에서는 항상 꺼져 있다.
/// - `-SMFailSave`: 기록 중 위치점 저장이 실패한다(실제 저장 실패 처리 경로를 탄다)
/// - `-SMFailWeather`: "다시 시도"를 누르기 전까지 날씨 조회가 실패한다
/// - `-SMFailVideoOnce`: 첫 동영상 만들기만 만드는 중 화면을 띄운 뒤 실패한다
/// - `-SMBanner battery|weak`: 배터리 12%(충전 안 함) 또는 약한 위치 신호를 실제 배너 조건에 넣는다
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
}
