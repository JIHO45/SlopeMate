import Foundation
import GRDB

// 익명 표본으로 보낼 기기 안 기록: 리프트 대기(R10), 설질 평가(R11). 보내기는 서버 기능(R12).
// sendState: pending(보낼 것), sent, dropped(동의 없음·철회). 보내는 쪽은 차량 재조회가 끝난 기록의 표본만 보낸다.

nonisolated struct LiftWait: Codable, Hashable, FetchableRecord, PersistableRecord {
    var recordingId: UUID
    var boardAt: Date
    var resortId: String
    var liftId: String
    var waitSec: Double
    var sendState: String

    static let databaseTableName = "lift_wait"
}

nonisolated struct SnowRating: Codable, Hashable, FetchableRecord, PersistableRecord {
    enum Value: String, Codable, CaseIterable { case ice, ok, slush }

    var recordingId: UUID
    var runStart: Date           // 하강을 가리키는 키. 하강이 길어져도 시작은 같다
    var runEnd: Date             // 답할 때의 하강 끝
    var resortId: String
    var slopeId: String          // 답할 때 붙은 슬로프. 나중에 다시 판정해도 바꾸지 않는다
    var value: Value
    var ratedAt: Date
    var sendState: String

    static let databaseTableName = "snow_rating"
}

/// 기록 중 화면의 설질 질문 칸 (R11, 04-flows 설질 평가 칸).
nonisolated enum SnowPrompt {
    /// 하강 끝에서 이 시간이 지나면 칸을 닫고 답을 받지 않는다
    static let window: TimeInterval = 30 * 60

    /// 진행 중 기록의 판정만 넘긴다. 마지막 하강 하나만 본다(아직 내려가는 중이어도 — 리프트로 오르기 전 줄에서 여는 경우가 흔함).
    /// 슬로프를 식별하지 못하면 묻지 않는다(이전 하강으로 돌아가지 않음).
    static func target(_ summary: RunDetector.Summary, points: [Point], map: SlopeMap?, now: Date,
                       enabled: Bool = Settings.snowPromptOn) -> RunDetector.Run? {
        guard enabled, let map, var run = summary.runs.last, now <= run.end.addingTimeInterval(window) else { return nil }
        run.slopeId = SlopeMatcher.match(RunDetector.clean(points.filter { $0.t >= run.start && $0.t <= run.end }, .init()), map: map)
        return run.slopeId == nil ? nil : run
    }

    /// 하루 기록 목록에 답을 붙인다: 같은 기록의 하강 중 [runStart, runEnd]와 가장 많이 겹치는 하나에만.
    /// 최대 겹침이 동률이거나 겹침이 없으면 붙이지 않는다. 한 하강에 둘 이상이면 마지막 답. 결과: 하강 번호 → 답
    static func attach(_ ratings: [SnowRating], to runs: [RunDetector.Run]) -> [Int: SnowRating] {
        var out: [Int: SnowRating] = [:]
        for r in ratings.sorted(by: { $0.ratedAt < $1.ratedAt }) {
            let overlaps = runs.map { min($0.end, r.runEnd).timeIntervalSince(max($0.start, r.runStart)) }
            guard let best = overlaps.max(), best >= 0, overlaps.count(where: { $0 == best }) == 1,
                  let i = overlaps.firstIndex(of: best) else { continue }
            out[i] = r
        }
        return out
    }
}

nonisolated extension AppDatabase {
    /// 설질 답 저장. 다시 답하면 행 전체를 바꾼다(보낼 상태도 이 답 시각으로 다시 정함). 이미 보낸 답은 바꾸지 않는다.
    /// run은 지금 질문 대상(SnowPrompt.target)이어야 하고, 하강 끝 + 30분이 지났으면 false.
    @discardableResult
    func rate(_ rec: Recording, run: RunDetector.Run, value: SnowRating.Value, now: Date) throws -> Bool {
        guard let slopeId = run.slopeId, now <= run.end.addingTimeInterval(SnowPrompt.window) else { return false }
        return try queue.write { db in
            let old = try SnowRating.fetchOne(db, key: ["recordingId": rec.id, "runStart": run.start])
            if old?.sendState == "sent" { return false }
            try SnowRating(recordingId: rec.id, runStart: run.start, runEnd: run.end, resortId: rec.resortId, slopeId: slopeId,
                           value: value, ratedAt: now, sendState: Settings.sendState(at: now)).save(db)
            return true
        }
    }

    func snowRatings(_ rec: Recording) throws -> [SnowRating] {
        try queue.read { try SnowRating.filter(Column("recordingId") == rec.id).order(Column("runStart")).fetchAll($0) }
    }

    func liftWaits(_ rec: Recording) throws -> [LiftWait] {
        try queue.read { try LiftWait.filter(Column("recordingId") == rec.id).order(Column("boardAt")).fetchAll($0) }
    }

    /// 동의를 끄면 아직 안 보낸 표본을 버린다(R12)
    func dropPendingSamples() throws {
        try queue.write { db in
            for t in ["lift_wait", "snow_rating"] {
                try db.execute(sql: "UPDATE \(t) SET sendState = 'dropped' WHERE sendState = 'pending'")
            }
        }
    }

    /// 최종 판정의 리프트 대기로 표본을 맞춘다. 판정에서 사라진 미전송 표본은 지우고, 남은 미전송 표본은 값만 갱신(보낼 상태는 그대로),
    /// 새 표본은 탑승 시각으로 보낼 상태를 정한다. 보낸 표본은 건드리지 않는다. 캐시 저장과 같은 트랜잭션에서 부른다.
    static func syncLiftWaits(_ db: Database, _ rec: Recording, _ summary: RunDetector.Summary) throws {
        let fresh = summary.ascents.compactMap { a -> LiftWait? in
            guard let lift = a.liftId, let board = a.boardAt, let wait = a.waitSec else { return nil }
            return LiftWait(recordingId: rec.id, boardAt: board, resortId: rec.resortId, liftId: lift, waitSec: wait,
                            sendState: Settings.sendState(at: board))
        }
        let old = try LiftWait.filter(Column("recordingId") == rec.id).fetchAll(db)
        for o in old where o.sendState != "sent" && !fresh.contains(where: { $0.boardAt == o.boardAt }) { try o.delete(db) }
        for var n in fresh {
            if let o = old.first(where: { $0.boardAt == n.boardAt }) {
                if o.sendState == "sent" { continue }
                n.sendState = o.sendState
            }
            try n.save(db)
        }
    }
}
