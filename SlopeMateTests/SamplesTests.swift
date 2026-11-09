import Foundation
import GRDB
import Testing
@testable import SlopeMate

/// 리프트 대기(R10), 설질 평가(R11), 하루 경로·결과 저장(R50), 동의(R12).
/// 동의 값이 UserDefaults 전역이라 순서대로 돈다.
@Suite(.serialized)
struct SamplesTests {
    static let mPerLon = cos(37.2 * .pi / 180) * 111_320
    static let liftTop = 37.2 + 900 / 111_195

    /// Track 좌표(경도 128.8, 북쪽으로 이동)에 맞춘 지도: 위도 37.2에서 북쪽 900m 리프트 L, 그 뒤 슬로프 S
    static func map() throws -> SlopeMap {
        let json: [String: Any] = [
            "resort_id": "test", "source": "test", "osm_timestamp": "2026-11-01",
            "slopes": [["id": "S", "osm_ids": [], "lines": [[[liftTop, 128.8], [liftTop + 0.05, 128.8]]]]],
            "lifts": [["id": "L", "kind": "chair_lift", "osm_id": "1", "line": [[37.2, 128.8], [liftTop, 128.8]]]],
        ]
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(SlopeMap.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// 남쪽 200m에서 걸어와 탑승장(위도 37.2)에서 queue초 기다린 뒤 리프트 → 하강
    static func track(queue: Int, queueEast: Double = 0, approach: Bool = true) -> Track {
        var tr = Track()
        if approach {
            tr.lat = 37.2 - 200 / 111_195
            tr.go(40, climb: 0, speed: 5)
        } else {
            tr.lat = 37.2
        }
        let q0 = tr.t
        tr.go(queue, climb: 0, speed: 0)
        let q1 = tr.t
        if queueEast != 0 {
            tr.pts = tr.pts.map { p in var p = p; if p.t > q0 && p.t <= q1 { p.lon += queueEast / mPerLon }; return p }
        }
        tr.go(300, climb: 300, speed: 3)
        tr.go(180, climb: -300, speed: 10)
        return tr
    }

    // MARK: 리프트 대기 (R10)

    @Test func waitInQueue() throws {
        let s = RunDetector.detect(Self.track(queue: 300).pts, map: try Self.map())
        let a = try #require(s.ascents.first)
        #expect(a.liftId == "L")
        // 반경 50m에 들어선 때(걸어서 ~10초 전) ~ 반경을 벗어난 때(리프트로 ~16초 뒤)
        #expect((300...340).contains(try #require(a.waitSec)))
        #expect(s.runs.count == 1)
    }

    /// 줄이 탑승장에서 40m 떨어져 오래 기다려도, 리프트는 실제로 오르는 점으로 식별한다
    @Test func longQueueOffLineStillMatches() throws {
        let s = RunDetector.detect(Self.track(queue: 1200, queueEast: 40).pts, map: try Self.map())
        let a = try #require(s.ascents.first)
        #expect(a.liftId == "L")
        #expect(a.waitSec != nil)
    }

    @Test func longStayIsNotWait() throws {
        let a = try #require(RunDetector.detect(Self.track(queue: 2400).pts, map: try Self.map()).ascents.first)
        #expect(a.liftId == "L")
        #expect(a.waitSec == nil)
    }

    /// 수신 시작부터 탑승장에 있었으면 도착 시각을 몰라 버린다
    @Test func stayFromRecordingStartDropped() throws {
        let a = try #require(RunDetector.detect(Self.track(queue: 300, approach: false).pts, map: try Self.map()).ascents.first)
        #expect(a.liftId == "L")
        #expect(a.waitSec == nil)
    }

    @Test func ascentsWithoutMap() {
        var tr = Track()
        for _ in 0..<3 { tr.lap() }
        let s = RunDetector.detect(tr.pts)
        #expect(s.ascents.count == 3)
        #expect(s.ascents.allSatisfy { $0.liftId == nil && abs($0.rise - 300) < 5 })
    }

    // MARK: 설질 (R11)

    @Test func promptTargetsLastIdentifiedRun() throws {
        let tr = Self.track(queue: 60)
        let s = RunDetector.detect(tr.pts)
        let run = try #require(s.runs.last)
        let map = try Self.map()
        #expect(SnowPrompt.target(s, points: tr.pts, map: map, now: run.end, enabled: true)?.slopeId == "S")
        #expect(SnowPrompt.target(s, points: tr.pts, map: map, now: run.end + 31 * 60, enabled: true) == nil)
        #expect(SnowPrompt.target(s, points: tr.pts, map: map, now: run.end, enabled: false) == nil)
        #expect(SnowPrompt.target(s, points: tr.pts, map: nil, now: run.end, enabled: true) == nil)
    }

    @Test func attachByLargestUniqueOverlap() {
        let t0 = Date(timeIntervalSince1970: 0)
        func run(_ a: Double, _ b: Double) -> RunDetector.Run {
            .init(start: t0 + a, end: t0 + b, distance: 0, drop: 0, maxSpeed: 0, avgSpeed: 0, movingTime: 0)
        }
        func rating(_ a: Double, _ b: Double) -> SnowRating {
            .init(recordingId: UUID(), runStart: t0 + a, runEnd: t0 + b, resortId: "r", slopeId: "s", value: .ice, ratedAt: t0 + b, sendState: "dropped")
        }
        #expect(SnowPrompt.attach([rating(0, 100)], to: [run(0, 30), run(40, 100)]).keys.sorted() == [1])
        // 차량 재판정으로 같은 길이 둘로 나뉘면 숨긴다
        #expect(SnowPrompt.attach([rating(0, 100)], to: [run(0, 50), run(50, 100)]).isEmpty)
        #expect(SnowPrompt.attach([rating(0, 100)], to: [run(200, 300)]).isEmpty)
    }

    // MARK: 저장·동의 (R11, R12)

    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    func db() throws -> AppDatabase {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try AppDatabase(path: dir.appending(path: "t.sqlite").path)
    }

    @Test func sendStateFollowsConsentTime() {
        let t = Date(timeIntervalSince1970: 1000)
        #expect(Settings.sendState(at: t, consentSince: nil) == "dropped")
        #expect(Settings.sendState(at: t, consentSince: t - 1) == "pending")
        #expect(Settings.sendState(at: t, consentSince: t + 1) == "dropped")
    }

    @Test func rateWindowReplaceAndConsent() throws {
        let db = try db()
        try Settings.setConsent(false, db: db)
        let rec = try db.createRecording(resortId: "test", at: Date(timeIntervalSince1970: 0))
        let run = RunDetector.Run(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200), distance: 0, drop: 0,
                                  maxSpeed: 0, avgSpeed: 0, movingTime: 0, slopeId: "S")
        #expect(try db.rate(rec, run: run, value: .ice, now: run.end + 10))
        #expect(try db.snowRatings(rec).map(\.sendState) == ["dropped"])
        // 동의를 켠 뒤 다시 답하면 새 표본
        try Settings.setConsent(true, db: db, now: run.end + 20)
        #expect(try db.rate(rec, run: run, value: .slush, now: run.end + 30))
        #expect(try db.snowRatings(rec).map(\.value) == [.slush])
        #expect(try db.snowRatings(rec).map(\.sendState) == ["pending"])
        // 30분 지나면 받지 않는다
        #expect(try !db.rate(rec, run: run, value: .ok, now: run.end + 31 * 60))
        // 보낸 답은 바꾸지 않는다
        try db.queue.write { try $0.execute(sql: "UPDATE snow_rating SET sendState = 'sent'") }
        #expect(try !db.rate(rec, run: run, value: .ok, now: run.end + 40))
        // 끄면 미전송은 버림
        try db.queue.write { try $0.execute(sql: "UPDATE snow_rating SET sendState = 'pending'") }
        try Settings.setConsent(false, db: db)
        #expect(try db.snowRatings(rec).map(\.sendState) == ["dropped"])
    }
}
