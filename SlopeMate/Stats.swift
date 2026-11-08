import Foundation

/// 집계 규칙 (03-requirements 5장). 모든 화면과 크루 순위가 이 함수를 쓴다.
/// 합계는 저장하지 않고 기록에서 매번 계산한다(05-design 4장).
nonisolated enum Stats {
    /// 하루 기록: 영업일 × 리조트.
    struct Day: Identifiable {
        var date: Date               // 영업일 시작(06:00)
        var resortId: String
        var runs: [RunDetector.Run]
        var usedGPSAltitude: Bool
        var id: String { "\(date.timeIntervalSince1970)-\(resortId)" }
        var isVisit: Bool { !runs.isEmpty }
    }

    struct Totals: Equatable {
        var visitDays = 0
        var runs = 0
        var distance = 0.0           // m
        var drop = 0.0               // m
        var maxSpeed = 0.0           // m/s
        var movingTime = 0.0         // s
        var avgSpeed: Double { movingTime > 0 ? distance / movingTime : 0 }
    }

    /// 하강은 시작 시각의 영업일에 속한다(자정 넘은 심야 하강은 전날). 하강이 없는 기록도 기록 시작 영업일의 하루로 남는다.
    static func days(_ recordings: [(Recording, RunDetector.Summary)]) -> [Day] {
        var out: [String: Day] = [:]
        for (rec, summary) in recordings {
            // 경고는 OR로 합친다: 입력 순서와 관계없이 GPS 고도를 쓴 기록이 하나라도 있으면 켠다
            func add(_ t: Date, _ runs: [RunDetector.Run]) {
                let d = Day(date: BusinessDay.start(of: t), resortId: rec.resortId, runs: [], usedGPSAltitude: false)
                out[d.id, default: d].runs += runs
                out[d.id]!.usedGPSAltitude = out[d.id]!.usedGPSAltitude || summary.usedGPSAltitude
            }
            add(rec.startedAt, [])
            for run in summary.runs { add(run.start, [run]) }
        }
        return out.values
            .map { var d = $0; d.runs.sort { $0.start < $1.start }; return d }
            .sorted { ($0.date, $0.resortId) > ($1.date, $1.resortId) }
    }

    /// 방문일은 하강이 있는 영업일 수. 같은 날 두 리조트는 전체 1일.
    static func totals(_ days: [Day]) -> Totals {
        let runs = days.flatMap(\.runs)
        return Totals(
            visitDays: Set(days.filter(\.isVisit).map(\.date)).count,
            runs: runs.count,
            distance: runs.reduce(0) { $0 + $1.distance },
            drop: runs.reduce(0) { $0 + $1.drop },
            maxSpeed: runs.map(\.maxSpeed).max() ?? 0,
            movingTime: runs.reduce(0) { $0 + $1.movingTime })
    }

    /// 리조트별 합계: 같은 날 두 리조트면 각 리조트에 1일씩.
    static func totalsByResort(_ days: [Day]) -> [String: Totals] {
        Dictionary(grouping: days, by: \.resortId).mapValues(totals)
    }

    /// 시즌: 11월 1일 ~ 다음 해 4월 30일, 이름은 "2026-27". 5~10월 영업일은 시즌 밖(nil).
    static func season(of businessDay: Date) -> String? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let c = cal.dateComponents([.year, .month], from: businessDay)
        guard let y = c.year, let m = c.month else { return nil }
        let start = m >= 11 ? y : m <= 4 ? y - 1 : nil
        return start.map { String(format: "%d-%02d", $0, ($0 + 1) % 100) }
    }

    static func days(_ days: [Day], inSeason s: String) -> [Day] {
        days.filter { season(of: $0.date) == s }
    }
}
