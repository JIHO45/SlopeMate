import Foundation

/// S20 시즌 결산 카드 계산 (R53). 숫자는 S9와 같은 Stats·PassValue로 낸다. 해당 없는 카드는 빼므로 7장보다 적을 수 있다.
nonisolated enum SeasonRecap {
    struct SessionShare: Equatable {
        var kind: SessionKind
        var runs: Int
        var percent: Int
    }

    enum Card: Equatable {
        case totals(visitDays: Int, runs: Int, distance: Double)
        case drop(total: Double, perDay: Double)
        case sessions([SessionShare])
        case topResort(resortId: String, days: Int, of: Int, runs: Int, distance: Double)
        case topDay(date: Date, resortId: String, runs: Int, distance: Double, drop: Double)
        case topSlope(name: String, resortId: String, runs: Int)
        case pass(name: String, visits: Int, perVisit: Int, ticket: Int)

        /// 이용권 없음 안내 카드에 적는 이름
        var lockedName: String {
            switch self {
            case .totals: "방문일"
            case .drop: "고도차"
            case .sessions: "세션별 비율"
            case .topResort: "가장 많이 간 리조트"
            case .topDay: "가장 많이 탄 날"
            case .topSlope: "가장 많이 탄 슬로프"
            case .pass: "시즌권 본전"
            }
        }
    }

    /// session: 하강의 세션(시간표 없으면 nil). slopeName: 슬로프 이름이 켜진 리조트의 이름 있는 슬로프만, 아니면 nil.
    static func cards(days all: [Stats.Day], season: String,
                      passes: [(pass: SeasonPass, resorts: [String])] = [],
                      session: (RunDetector.Run, String) -> SessionKind? = { _, _ in nil },
                      slopeName: (String, String) -> String? = { _, _ in nil }) -> [Card] {
        let mine = Stats.days(all, inSeason: season).filter(\.isVisit)
        let t = Stats.totals(mine)
        guard t.visitDays > 0 else { return [] }
        var out: [Card] = [.totals(visitDays: t.visitDays, runs: t.runs, distance: t.distance),
                           .drop(total: t.drop, perDay: t.drop / Double(t.visitDays))]

        // 세션별 비율: 주간·야간·심야로 나뉜 하강만 센다. 합이 100이 되도록 큰 나머지 순으로 1%씩 더한다
        var counts: [SessionKind: Int] = [:]
        for d in mine { for r in d.runs { if let k = session(r, d.resortId), k != .unclassified { counts[k, default: 0] += 1 } } }
        let n = counts.values.reduce(0, +)
        if n > 0 {
            let kinds: [SessionKind] = [.day, .night, .lateNight]
            var shares = kinds.map { SessionShare(kind: $0, runs: counts[$0] ?? 0, percent: (counts[$0] ?? 0) * 100 / n) }
            let order = shares.indices.sorted { (shares[$0].runs * 100 % n) > (shares[$1].runs * 100 % n) }
            for i in order.prefix(100 - shares.reduce(0) { $0 + $1.percent }) { shares[i].percent += 1 }
            out.append(.sessions(shares.filter { $0.runs > 0 }))
        }

        if let e = Stats.totalsByResort(mine).max(by: { ($0.value.visitDays, $0.value.runs, $1.key) < ($1.value.visitDays, $1.value.runs, $0.key) }) {
            out.append(.topResort(resortId: e.key, days: e.value.visitDays, of: t.visitDays, runs: e.value.runs, distance: e.value.distance))
        }
        // 같은 횟수면 이른 날
        if let d = mine.max(by: { ($0.runs.count, $1.date) < ($1.runs.count, $0.date) }) {
            let s = Stats.totals([d])
            out.append(.topDay(date: d.date, resortId: d.resortId, runs: s.runs, distance: s.distance, drop: s.drop))
        }

        var slopes: [String: (name: String, resortId: String, runs: Int)] = [:]
        for d in mine {
            for r in d.runs {
                guard let id = r.slopeId, let name = slopeName(d.resortId, id) else { continue }
                slopes["\(d.resortId)/\(id)", default: (name, d.resortId, 0)].runs += 1
            }
        }
        if let s = slopes.values.max(by: { ($0.runs, $1.name) < ($1.runs, $0.name) }) {
            out.append(.topSlope(name: s.name, resortId: s.resortId, runs: s.runs))
        }

        // 시즌권 본전: 1장이면 그 시즌권, 2장 이상이면 S9의 "시즌권 전체"와 같은 값
        let pv = PassValue.compute(passes, days: all, season: season)
        let mineP = passes.filter { $0.pass.season == season }
        let ticket = mineP.reduce(0) { $0 + (pv.ticketValue[$1.pass.id] ?? 0) }
        if mineP.count == 1, let v = pv.perPass[mineP[0].pass.id] ?? nil {
            out.append(.pass(name: mineP[0].pass.name, visits: v.visits, perVisit: Int(v.perVisit.rounded()), ticket: ticket))
        } else if mineP.count > 1, let v = pv.total {
            out.append(.pass(name: "시즌권 전체", visits: v.visits, perVisit: Int(v.perVisit.rounded()), ticket: ticket))
        }
        return out
    }

    /// 유료 기능 잠금(2026-11-14 결정): 보고 있는 기록의 시즌 이용권을 샀을 때만 열린다.
    /// 지난 시즌 이용권은 팔지 않으므로 사지 않은 지난 시즌은 S18 대신 안내만 보여 준다.
    enum Lock: Equatable { case open, ticket, pastSeason }

    static func lock(season: String, owned: Set<String>, current: String) -> Lock {
        owned.contains(season) ? .open : season == current ? .ticket : .pastSeason
    }

    static let pastSeasonNote = "지난 시즌 기록은 그 시즌 이용권으로 열려요"

    /// 시즌 끝(4월 30일)이 지났으면 최종 결산. "2026-27"은 2027년 5월 1일 00:00(한국)부터
    static func isFinal(season: String, now: Date = .now) -> Bool {
        guard let y = Int(season.prefix(4)) else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return now >= cal.date(from: DateComponents(year: y + 1, month: 5, day: 1))!
    }
}
