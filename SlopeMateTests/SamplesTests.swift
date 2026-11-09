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
}
