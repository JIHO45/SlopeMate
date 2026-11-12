import CoreMotion
import FirebaseAppCheck
import Foundation
import GRDB
import UIKit

/// 익명 표본 보내기 (R12, 05-design 6장 "표본 전송", decisions 2026-11-12).
/// 차량 판정이 확정된 기록의 표본만, 기기 전체에서 같은 리조트·슬로프(리프트)·한국 날짜·정시 1시간에 하나만, 표본마다 한 번만 보낸다.
/// 계정 토큰 없이 일반 HTTPS로 보내고, 정확한 시각 대신 한국 날짜와 15분 슬롯만 담는다.
nonisolated enum SampleSend {
    /// 보낼 내용. 정확한 시각·기록 ID는 들어가지 않는다
    struct Outgoing: Equatable {
        enum Kind: Equatable { case snow, wait }
        var kind: Kind
        var recordingId: UUID
        var at: Date          // 행 키(runStart·boardAt). 보내지 않는다
        var body: [String: AnyHashable]
    }

    private static let kst = TimeZone(identifier: "Asia/Seoul")!
    private static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = kst; return c }

    /// 한국 날짜 "YYYY-MM-DD"
    static func date(_ t: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: t)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    /// 15분 슬롯 0~95
    static func slot(_ t: Date) -> Int {
        let c = cal.dateComponents([.hour, .minute], from: t)
        return c.hour! * 4 + c.minute! / 15
    }
    /// 사람 수를 세는 단위: 리조트·슬로프(리프트)·한국 날짜·정시 1시간
    static func dedupeKey(_ kind: Outgoing.Kind, resort: String, id: String, at t: Date) -> String {
        "\(kind == .snow ? "s" : "w")|\(resort)|\(id)|\(date(t))|\(slot(t) / 4)"
    }
    /// 한국 날짜 D의 표본은 D+7일 24:00에 만료(서버는 8일까지 받는다)
    static func expired(_ t: Date, now: Date) -> Bool {
        now >= cal.startOfDay(for: t).addingTimeInterval(8 * 86400)
    }

    /// 다시 보내도 되는 실패: 요청이 서버에 닿지 않은 것이 확실한 연결 오류뿐. 나머지는 중복 집계를 피하려고 버린다
    static func retryable(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
                .secureConnectionFailed, .dataNotAllowed, .internationalRoamingOff].contains(e.code)
    }

    static let endpoint = URL(string: "https://asia-northeast3-slopemate-f9a5b.cloudfunctions.net/submitSample")!
}

nonisolated extension AppDatabase {
    /// 지금 보낼 표본을 고르고, 만료·사라진 하강·같은 시간 중복은 `dropped`로 바꾼다.
    /// motionSettled: 동작 권한이 없거나 지원하지 않아 차량 조회를 기다릴 필요가 없음.
    func samplesToSend(now: Date, motionSettled: Bool, map: (String) -> SlopeMap?) throws -> [SampleSend.Outgoing] {
        let stamp = { Self.osmStamp(map($0)) }
        let stale = Set(try recordingsNeedingCache(osmStamp: stamp).map(\.id))
        // 만료(8일) 안의 표본만 남으니 최근 9일 기록만 본다
        let since = now.addingTimeInterval(-9 * 86400)
        var drops: [(table: String, rec: UUID, key: String, at: Date)] = []
        var unsettledOld: [UUID] = []
        let recs = try queue.read { try Recording.filter(Column("endedAt") != nil && Column("startedAt") >= since).fetchAll($0) }
            .filter { rec in
                // 동작 권한이 있으면 종료 15분 뒤의 차량 조회를 기다린다. 6일(조회 가능 기간)이 지나도록 확정되지 않으면 버린다.
                // 캐시 확인보다 먼저 해야 캐시가 낡은 기록도 버려진다
                let settled = motionSettled || rec.vehicleQueriedAt.map { $0 >= rec.endedAt!.addingTimeInterval(15 * 60) } ?? false
                if !settled {
                    if rec.startedAt < now.addingTimeInterval(-6 * 86400) { unsettledOld.append(rec.id) }
                    return false
                }
                return !stale.contains(rec.id)
            }
        var out: [SampleSend.Outgoing] = []
        for rec in recs {
            let ratings = try snowRatings(rec), waits = try liftWaits(rec)
            guard ratings.contains(where: { $0.sendState == "pending" }) || waits.contains(where: { $0.sendState == "pending" }) else { continue }
            // 화면과 같은 겹침 기준으로 지금 하강에 붙는 답만. 한 기록의 오류가 나머지를 막지 않게 건너뛴다
            guard let runs = try? cache(rec, map: map(rec.resortId)).summary.runs else { continue }
            let attached = Set(SnowPrompt.attach(ratings, to: runs).values.map(\.runStart))
            for r in ratings where r.sendState == "pending" {
                if !attached.contains(r.runStart) || SampleSend.expired(r.runStart, now: now) {
                    drops.append(("snow_rating", rec.id, "runStart", r.runStart)); continue
                }
                out.append(.init(kind: .snow, recordingId: rec.id, at: r.runStart, body: [
                    "kind": "snow", "resort": r.resortId, "slope": r.slopeId, "date": SampleSend.date(r.runStart),
                    "slot": SampleSend.slot(r.runStart), "value": r.value.rawValue]))
            }
            for w in waits where w.sendState == "pending" {
                if SampleSend.expired(w.boardAt, now: now) { drops.append(("lift_wait", rec.id, "boardAt", w.boardAt)); continue }
                out.append(.init(kind: .wait, recordingId: rec.id, at: w.boardAt, body: [
                    "kind": "wait", "resort": w.resortId, "lift": w.liftId, "date": SampleSend.date(w.boardAt),
                    "slot": SampleSend.slot(w.boardAt), "sec": Int(w.waitSec.rounded())]))
            }
        }

        // 기기 전체에서 같은 시간 단위에 이미 보낸 것이 있거나, 이번 것끼리 겹치면 먼저 것 하나만
        var used = Set(try queue.read { db in
            try SnowRating.filter(Column("sendState") == "sent" && Column("runStart") >= since).fetchAll(db).map { SampleSend.dedupeKey(.snow, resort: $0.resortId, id: $0.slopeId, at: $0.runStart) }
                + LiftWait.filter(Column("sendState") == "sent" && Column("boardAt") >= since).fetchAll(db).map { SampleSend.dedupeKey(.wait, resort: $0.resortId, id: $0.liftId, at: $0.boardAt) }
        })
        var kept: [SampleSend.Outgoing] = []
        for o in out.sorted(by: { $0.at < $1.at }) {
            let key = SampleSend.dedupeKey(o.kind, resort: o.body["resort"] as! String, id: (o.body["slope"] ?? o.body["lift"]) as! String, at: o.at)
            if used.insert(key).inserted { kept.append(o) } else { drops.append(o.kind == .snow ? ("snow_rating", o.recordingId, "runStart", o.at) : ("lift_wait", o.recordingId, "boardAt", o.at)) }
        }
        try queue.write { db in
            for id in unsettledOld {
                for t in ["lift_wait", "snow_rating"] {
                    try db.execute(sql: "UPDATE \(t) SET sendState = 'dropped' WHERE recordingId = ? AND sendState = 'pending'", arguments: [id])
                }
            }
            for d in drops {
                try db.execute(sql: "UPDATE \(d.table) SET sendState = 'dropped' WHERE recordingId = ? AND \(d.key) = ? AND sendState = 'pending'",
                               arguments: [d.rec, d.at])
            }
        }
        return kept
    }

    /// pending → sent(보내기 직전) 또는 sent → pending(연결 실패). 바뀌었으면 true
    @discardableResult
    func markSample(_ o: SampleSend.Outgoing, from: String, to: String) throws -> Bool {
        let (table, key) = o.kind == .snow ? ("snow_rating", "runStart") : ("lift_wait", "boardAt")
        return try queue.write { db in
            try db.execute(sql: "UPDATE \(table) SET sendState = ? WHERE recordingId = ? AND \(key) = ? AND sendState = ?",
                           arguments: [to, o.recordingId, o.at, from])
            return db.changesCount > 0
        }
    }
}

/// 앱이 앞에 있는 동안 표본을 하나씩, 사이에 무작위 2~20초를 두고 보낸다
@MainActor final class SampleSender {
    private let db: AppDatabase
    /// 앞에 올 때마다 새 차례. 이전 차례는 다음 표본 전에 멈춘다(겹쳐도 markSample이 한 번만 보내게 함)
    private var generation = 0

    init(db: AppDatabase) { self.db = db }

    private var allowed: Bool { Settings.consentSince != nil && ServerConfig.config.samples }

    func run() async {
        generation += 1
        let mine = generation
        guard allowed else { return }
        let motionSettled = !CMMotionActivityManager.isActivityAvailable() || CMMotionActivityManager.authorizationStatus() != .authorized
        let db = db
        let maps = SlopeMapCache()
        guard let batch = try? await Task.detached(priority: .utility, operation: {
            try db.samplesToSend(now: .now, motionSettled: motionSettled, map: maps.get)
        }).value else { return }
        for o in batch {
            guard generation == mine, !Task.isCancelled, allowed else { return }
            // 토큰을 먼저 받는다. 못 받으면 보내지 않고 다음 기회에
            guard let token = try? await AppCheck.appCheck().limitedUseToken().token else { return }
            guard allowed, (try? db.markSample(o, from: "pending", to: "sent")) == true else { continue }
            let task = UIApplication.shared.beginBackgroundTask(withName: "sample")
            var stop = false
            do {
                // 화면이 바뀌어 run이 취소돼도 이미 보낸 요청은 끝까지 기다린다(취소하면 결과를 모름)
                let body = o.body
                let status = try await Task { try await Self.post(body, token: token) }.value
                // 집계 전에 거부된 것이 확실한 응답(App Check 401, 과부하 429·503)은 되돌리고 이번 차례를 멈춘다
                if [401, 429, 503].contains(status) {
                    try? db.markSample(o, from: "sent", to: "pending")
                    stop = true
                }
            } catch {
                if SampleSend.retryable(error) { try? db.markSample(o, from: "sent", to: "pending") }
            }
            UIApplication.shared.endBackgroundTask(task)
            if stop { return }
            try? await Task.sleep(for: .seconds(Double.random(in: 2...20)))
        }
    }

    /// 쿠키·캐시 없는 세션. 응답 전체가 30초를 넘지 않게(백그라운드 작업 시간 안)
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }()

    /// HTTP 상태 코드. 본문은 보지 않는다
    private static func post(_ body: [String: AnyHashable], token: String) async throws -> Int {
        var req = URLRequest(url: SampleSend.endpoint, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Firebase-AppCheck")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, res) = try await session.data(for: req)
        return (res as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// 백그라운드에서 지도를 리조트당 한 번만 읽는다
private nonisolated final class SlopeMapCache: @unchecked Sendable {
    private var maps: [String: SlopeMap?] = [:]
    private let lock = NSLock()
    func get(_ id: String) -> SlopeMap? {
        lock.withLock {
            if let m = maps[id] { return m }
            let m = SlopeMap.load(resortId: id)
            maps[id] = .some(m)
            return m
        }
    }
}
