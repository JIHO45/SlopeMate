import Foundation

/// 홈과 기록 중 화면이 함께 쓰는 계산.
nonisolated enum HomeData {
    /// 하루 기록: 끝난 기록은 저장된 결과, 끝나지 않은 기록은 위치점에서 판정.
    static func days(_ db: AppDatabase, since: Date) throws -> [Stats.Day] {
        var maps: [String: SlopeMap?] = [:]
        let pairs = try db.recordings(since: since).map { rec -> (Recording, RunDetector.Summary) in
            if maps[rec.resortId] == nil { maps[rec.resortId] = .some(SlopeMap.load(resortId: rec.resortId)) }
            let map = maps[rec.resortId] ?? nil
            let s = rec.endedAt == nil ? RunDetector.detect(try db.points(rec), vehicle: try db.vehicle(rec), map: map)
                : try db.cache(rec, map: map).summary
            return (rec, s)
        }
        return Stats.days(pairs)
    }

    static var seoul: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        c.locale = Locale(identifier: "ko_KR")
        return c
    }

    /// 지금 시즌. 시즌 밖(5~10월)이면 다가오는 시즌.
    static func currentSeason(now: Date = .now) -> String {
        if let s = Stats.season(of: BusinessDay.start(of: now)) { return s }
        let y = seoul.component(.year, from: now)
        return String(format: "%d-%02d", y, (y + 1) % 100)
    }
}
