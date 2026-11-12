import Foundation
import GRDB
import Testing
@testable import SlopeMate

/// 익명 표본 보내기 (R12, decisions 2026-11-12). SamplesTests와 같은 직렬 묶음(동의 값이 전역).
extension SamplesTests {
    @Test func sampleDateSlotAndExpiry() {
        let t = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 17:00 KST
        #expect(SampleSend.date(t) == "2027-01-15")
        #expect(SampleSend.slot(t) == 68)
        #expect(SampleSend.slot(t + 14 * 60) == 68)
        #expect(SampleSend.slot(t + 15 * 60) == 69)
        // 자정 넘긴 심야 하강은 다음 날짜
        #expect(SampleSend.date(t + 7 * 3600 + 60) == "2027-01-16")
        #expect(SampleSend.slot(t + 7 * 3600 + 60) == 0)
        // 1시간 단위 중복 키: 17:00~17:59는 같고 18:00은 다름
        let k = { SampleSend.dedupeKey(.snow, resort: "r", id: "S", at: $0) }
        #expect(k(t) == k(t + 59 * 60))
        #expect(k(t) != k(t + 3600))
        #expect(k(t) != SampleSend.dedupeKey(.wait, resort: "r", id: "S", at: t))
        // 1월 15일 표본은 1월 23일 00:00 KST에 만료
        let deadline = Date(timeIntervalSince1970: 1_800_000_000 - 17 * 3600 + 8 * 86400)
        #expect(!SampleSend.expired(t, now: deadline - 1))
        #expect(SampleSend.expired(t, now: deadline))
    }

    @Test func retryOnlyWhenNotConnected() {
        #expect(SampleSend.retryable(URLError(.notConnectedToInternet)))
        #expect(SampleSend.retryable(URLError(.cannotConnectToHost)))
        #expect(!SampleSend.retryable(URLError(.timedOut)))
        #expect(!SampleSend.retryable(URLError(.networkConnectionLost)))
        #expect(!SampleSend.retryable(URLError(.cancelled)))
        #expect(!SampleSend.retryable(CancellationError()))
    }

    @Test func pickSamplesAfterVehicleSettledOncePerHour() throws {
        let db = try db()
        let tr = Self.track(queue: 300)
        try Settings.setConsent(false, db: db)
        try Settings.setConsent(true, db: db, now: tr.pts[0].t - 1)
        let rec = try db.createRecording(resortId: "test", at: tr.pts[0].t)
        for var p in tr.pts { p.recordingId = rec.id; try db.insert(&p) }
        try db.end(rec, at: tr.t, reason: "user")
        let map = try Self.map()
        let pick = { (now: Date, settled: Bool) in try db.samplesToSend(now: now, motionSettled: settled, map: { _ in map }) }
        let now = tr.t + 60

        // 캐시가 없으면(낡으면) 보내지 않는다
        #expect(try pick(now, true).isEmpty)
        let run = try #require(try db.refreshCache(rec, map: map).summary.runs.first)
        #expect(try db.rate(rec, run: run, value: .ice, now: run.end + 10))
        // 차량 재조회 전: 동작 권한이 있으면 기다리고, 없으면 바로
        #expect(try pick(now, false).isEmpty)
        let ready = try pick(now, true)
        #expect(ready.map(\.kind) == [.wait, .snow])
        let wait = ready[0].body, snow = ready[1].body
        #expect(Set(wait.keys) == ["kind", "resort", "lift", "date", "slot", "sec"])
        #expect(wait["lift"] as? String == "L" && (wait["sec"] as? Int ?? 0) > 0 && wait["date"] as? String == "2027-01-15")
        #expect(Set(snow.keys) == ["kind", "resort", "slope", "date", "slot", "value"])
        #expect(snow["slope"] as? String == "S" && snow["value"] as? String == "ice")
        // 종료 15분 뒤 차량 조회가 끝나면 동작 권한이 있어도 보낸다
        try db.setVehicle(rec, [], queriedAt: tr.t + 16 * 60)
        _ = try db.refreshCache(rec, map: map)
        #expect(try pick(now + 3600, false).count == 2)

        // 보낸 뒤에는 다시 고르지 않고, 연결 실패로 되돌리면 다시 고른다
        #expect(try db.markSample(ready[0], from: "pending", to: "sent"))
        #expect(!(try db.markSample(ready[0], from: "pending", to: "sent")))
        #expect(try pick(now, true).map(\.kind) == [.snow])
        #expect(try db.markSample(ready[0], from: "sent", to: "pending"))
        #expect(try pick(now, true).count == 2)
        try db.markSample(ready[0], from: "pending", to: "sent")

        // 같은 슬로프·같은 1시간에 다른 기록에서 이미 보낸 답이 있으면 버린다(사람 수를 세기 위함)
        let other = try db.createRecording(resortId: "test", at: tr.t)
        try db.queue.write { try SnowRating(recordingId: other.id, runStart: run.start + 120, runEnd: run.end + 120, resortId: "test", slopeId: "S",
                       value: .ok, ratedAt: run.end, sendState: "sent").insert($0) }
        #expect(try pick(now, true).isEmpty)
        #expect(try db.snowRatings(rec).map(\.sendState) == ["dropped"])
        try Settings.setConsent(false, db: db)
    }

    @Test func expiredAndDetachedRatingsDropped() throws {
        let db = try db()
        let tr = Self.track(queue: 300)
        try Settings.setConsent(false, db: db)
        try Settings.setConsent(true, db: db, now: tr.pts[0].t - 1)
        let rec = try db.createRecording(resortId: "test", at: tr.pts[0].t)
        for var p in tr.pts { p.recordingId = rec.id; try db.insert(&p) }
        try db.end(rec, at: tr.t, reason: "user")
        let map = try Self.map()
        let run = try #require(try db.refreshCache(rec, map: map).summary.runs.first)
        // 지금 하강과 겹치지 않는 답(차량 재판정으로 사라진 하강)
        try db.queue.write { try SnowRating(recordingId: rec.id, runStart: run.end + 3000, runEnd: run.end + 3100, resortId: "test", slopeId: "S",
                       value: .slush, ratedAt: run.end, sendState: "pending").insert($0) }
        #expect(try db.samplesToSend(now: tr.t + 60, motionSettled: true, map: { _ in map }).map(\.kind) == [.wait])
        #expect(try db.snowRatings(rec).map(\.sendState) == ["dropped"])
        // 8일째 0시(KST)가 되면 대기 표본도 버린다
        #expect(try db.samplesToSend(now: tr.t + 8 * 86400, motionSettled: true, map: { _ in map }).isEmpty)
        #expect(try db.liftWaits(rec).map(\.sendState) == ["dropped"])
        try Settings.setConsent(false, db: db)
    }

    @Test func unsettledVehicleAfterSixDaysDropped() throws {
        let db = try db()
        let tr = Self.track(queue: 300)
        try Settings.setConsent(false, db: db)
        try Settings.setConsent(true, db: db, now: tr.pts[0].t - 1)
        let rec = try db.createRecording(resortId: "test", at: tr.pts[0].t)
        for var p in tr.pts { p.recordingId = rec.id; try db.insert(&p) }
        try db.end(rec, at: tr.t, reason: "user")
        let map = try Self.map()
        _ = try db.refreshCache(rec, map: map)
        // 종료 직후 조회는 확정이 아니다(활동 기록이 늦게 들어옴)
        try db.setVehicle(rec, [], queriedAt: tr.t + 60)
        _ = try db.refreshCache(rec, map: map)
        #expect(try db.samplesToSend(now: tr.t + 5 * 86400, motionSettled: false, map: { _ in map }).isEmpty)
        #expect(try db.liftWaits(rec).map(\.sendState) == ["pending"])
        // 6일이 지나도록 확정되지 않으면 버린다
        #expect(try db.samplesToSend(now: tr.pts[0].t + 6 * 86400 + 60, motionSettled: false, map: { _ in map }).isEmpty)
        #expect(try db.liftWaits(rec).map(\.sendState) == ["dropped"])
        try Settings.setConsent(false, db: db)
    }
}
