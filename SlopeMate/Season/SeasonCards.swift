import Foundation

/// 시즌 화면(S9) 넘기는 카드 순서.
nonisolated enum SeasonCards {
    enum Card: Hashable { case calendar, goal, goalEmpty, recap, pass(UUID), passTotal, passEmpty }

    /// 채워진 카드: 달력, 목표, 결산, 시즌권…, 시즌권 합계(2장 이상). 빈 카드는 그 뒤. 최종 결산이면 결산이 맨 앞.
    /// 방문 0일이면 결산 카드는 뺀다(S9 빈 상태 v1).
    static func order(hasGoal: Bool, canSetGoal: Bool, passIds: [UUID], final: Bool, hasVisits: Bool = true) -> [Card] {
        let recap = hasVisits
        var out: [Card] = final && recap ? [.recap, .calendar] : [.calendar]
        if hasGoal { out.append(.goal) }
        if !final && recap { out.append(.recap) }
        out += passIds.map(Card.pass)
        if passIds.count > 1 { out.append(.passTotal) }
        if canSetGoal && !hasGoal { out.append(.goalEmpty) }
        if passIds.isEmpty { out.append(.passEmpty) }
        return out
    }
}
