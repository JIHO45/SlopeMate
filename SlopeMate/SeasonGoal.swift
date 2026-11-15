import Foundation

/// 개인 시즌 목표 (R36). 기기에만(UserDefaults) 시즌 문자열("2026-27") 키로 저장해, 시즌이 바뀌면 자연히 새로 정한다.
/// 방문일·하강 횟수 중 하나 이상. 무료라 이용권과 묶지 않는다.
nonisolated struct SeasonGoal: Codable, Equatable {
    var days: Int?
    var runs: Int?

    static let defaultDays = 10, defaultRuns = 100
    static let dayStep = 1, runStep = 10
    static let maxDays = 180, maxRuns = 9_990

    // MARK: 저장

    static func key(_ season: String) -> String { "seasonGoal.\(season)" }

    static func load(season: String, defaults: UserDefaults = .standard) -> SeasonGoal? {
        defaults.data(forKey: key(season)).flatMap { try? JSONDecoder().decode(SeasonGoal.self, from: $0) }
    }

    /// nil이나 빈 목표는 지운다
    static func save(_ goal: SeasonGoal?, season: String, defaults: UserDefaults = .standard) {
        if let goal, goal.days != nil || goal.runs != nil, let data = try? JSONEncoder().encode(goal) {
            defaults.set(data, forKey: key(season))
        } else {
            defaults.removeObject(forKey: key(season))
        }
    }

    // MARK: 스테퍼

    /// 다음 단위 배수로 올리거나 내린다. 최소 1(하강은 10 → 1 → 10), 최대 `max`.
    static func step(_ v: Int, up: Bool, by step: Int, max: Int) -> Int {
        let n = up ? (v / step + 1) * step : ((v - 1) / step) * step
        return Swift.min(max, Swift.max(1, n))
    }

    // MARK: 진행률

    struct Progress: Equatable {
        var value: Int
        var target: Int
        /// 넘겨도 1에서 멈춘다(실제 숫자는 `value`에 그대로)
        var fraction: Double { Swift.min(1, Double(value) / Double(Swift.max(target, 1))) }
        var done: Bool { value >= target }
        var left: Int { Swift.max(0, target - value) }
    }

    func progress(visitDays: Int, runs: Int) -> (days: Progress?, runs: Progress?) {
        (days.map { Progress(value: visitDays, target: $0) }, self.runs.map { Progress(value: runs, target: $0) })
    }
}
