import Foundation
import Testing
@testable import SlopeMate

/// 합성 트랙: 2초 간격, 북쪽으로 이동.
struct Track {
    var t = Date(timeIntervalSince1970: 1_800_000_000)
    var lat = 37.2
    var alt = 0.0
    var seq = 0
    var baro = true
    var baroZero = 0.0
    var pts: [Point] = []
    let rec = UUID()

    mutating func go(_ secs: Int, climb: Double, speed: Double) {
        for _ in 0..<secs / 2 {
            t += 2
            alt += climb * 2 / Double(secs)
            lat += speed * 2 / 111_195
            add(speed: speed)
        }
    }
    mutating func add(speed: Double) {
        pts.append(Point(recordingId: rec, t: t, lat: lat, lon: 128.8, hAcc: 5, gpsAlt: alt + 700, vAcc: 5, speed: speed,
                         baroAlt: baro ? alt - baroZero : nil, baroT: baro ? t : nil, seq: seq))
    }
    /// 수신 재시작: 기압 상대고도가 0부터 다시 시작
    mutating func restart() { seq += 1; baroZero = alt; t += 30 }
    mutating func lap() { go(300, climb: 300, speed: 3); go(180, climb: -300, speed: 10) }
}

struct RunDetectorTests {
    @Test func threeLaps() {
        var tr = Track()
        for _ in 0..<3 { tr.lap() }
        let s = RunDetector.detect(tr.pts)
        #expect(s.runs.count == 3)
        #expect(!s.usedGPSAltitude)
        for r in s.runs {
            #expect(abs(r.drop - 300) < 1)
            #expect(abs(r.distance - 1800) < 40)
            #expect(abs(r.avgSpeed - 10) < 0.3)
        }
    }

    /// 재시작 경계를 넘어 고도차를 계산하지 않고, 하강 중 재시작해도 하강 1회로 합친다(R4 중복 금지).
    @Test func restartBoundary() {
        var tr = Track()
        tr.go(300, climb: 300, speed: 3)
        tr.go(90, climb: -150, speed: 10)
        tr.restart()
        tr.go(90, climb: -150, speed: 10)
        tr.lap()
        let s = RunDetector.detect(tr.pts)
        #expect(s.runs.count == 2)
        #expect(abs(s.runs[0].drop - 300) < 5) // 2초 샘플 경계 오차
        #expect(abs(s.drop - 600) < 5)
    }

    /// R49: 차량 구간 안에 점이 하나도 없어도 앞뒤를 잇지 않는다. 산 위에서 차를 타고 내려온 고도차는 하강이 아니다.
    @Test func vehicleGapWithoutPoints() {
        var tr = Track()
        tr.lap()
        tr.go(300, climb: 300, speed: 3)        // 리프트로 올라감
        let carFrom = tr.t
        tr.t += 1800; tr.alt -= 600; tr.lat += 0.2 // 30분 동안 점 없이 600m 아래로(차)
        let carTo = tr.t
        tr.go(60, climb: 0, speed: 0.5)          // 주차장에서 조금 걸음
        #expect(RunDetector.detect(tr.pts).runs.count == 2) // 차량 구간을 모르면 하강으로 셈
        let s = RunDetector.detect(tr.pts, vehicle: [DateInterval(start: carFrom, end: carTo)])
        #expect(s.runs.count == 1)
    }

    /// R49: 차량 구간 안의 점은 버리고, 앞뒤 하강을 합치지 않는다.
    @Test func vehicleSplitsWithoutMerging() {
        var tr = Track()
        tr.go(300, climb: 300, speed: 3)
        tr.go(90, climb: -150, speed: 10)         // 하강 중
        let carFrom = tr.t
        tr.go(120, climb: -200, speed: 15)        // 차량
        let carTo = tr.t
        tr.go(90, climb: -100, speed: 10)
        let s = RunDetector.detect(tr.pts, vehicle: [DateInterval(start: carFrom, end: carTo)])
        #expect(s.runs.count == 2) // 차에서 내린 뒤 걸어 내려간 것은 따로 센다. 차 앞뒤를 하나로 합치지 않음
        #expect(abs(s.runs[0].drop - 150) < 5)
        #expect(abs(s.runs[1].drop - 100) < 5)
        #expect(s.runs.allSatisfy { $0.end <= carFrom || $0.start >= carTo })
    }

    /// R9: 재시작으로 나뉜 하강은 합친 뒤 전체 점으로 한 번 맞춘다. 뒤 조각만 덮는 슬로프는 절반이라 이름을 붙이지 않는다.
    @Test func slopeMatchedAfterMerge() throws {
        func map(_ fromLat: Double, _ toLat: Double) throws -> SlopeMap {
            let json = #"{"resort_id":"t","source":"","osm_timestamp":"","lifts":[],"slopes":[{"id":"t-s01","osm_ids":[],"lines":[[[\#(fromLat),128.8],[\#(toLat),128.8]]]}]}"#
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            return try d.decode(SlopeMap.self, from: Data(json.utf8))
        }
        var tr = Track()
        tr.go(300, climb: 300, speed: 3)
        tr.go(90, climb: -150, speed: 10)
        let half = tr.lat
        tr.restart()
        tr.go(90, climb: -150, speed: 10)
        let whole = RunDetector.detect(tr.pts, map: try map(37.2, 37.25))
        #expect(whole.runs.count == 1 && whole.runs[0].slopeId == "t-s01")
        let back = RunDetector.detect(tr.pts, map: try map(half, 37.25))
        #expect(back.runs.count == 1 && back.runs[0].slopeId == nil)
    }

    /// 기압계가 중간에 멈춰 GPS 고도(기준 +700m)로 바뀌어도 두 기준을 섞지 않는다.
    @Test func altitudeSourceSwitch() {
        var tr = Track()
        tr.lap()
        tr.baro = false
        tr.lap()
        let s = RunDetector.detect(tr.pts)
        #expect(s.runs.count == 2)
        #expect(s.usedGPSAltitude)
        #expect(s.runs.allSatisfy { abs($0.drop - 300) < 1 })
    }

    /// 기압 값이 잠깐 오래돼도(사이에 끼인 GPS 점) 하강이 쪼개지지 않는다.
    @Test func staleBaroBlip() {
        var tr = Track()
        tr.go(300, climb: 300, speed: 3)
        tr.go(90, climb: -150, speed: 10)
        tr.baro = false
        tr.go(10, climb: -20, speed: 10)
        tr.baro = true
        tr.go(80, climb: -130, speed: 10)
        let s = RunDetector.detect(tr.pts)
        #expect(s.runs.count == 1)
        #expect(!s.usedGPSAltitude)
    }

    /// 기압 첫 값보다 위치가 먼저 와도 "고도 정확도 낮음"을 띄우지 않는다.
    @Test func firstPointsBeforeBaro() {
        var tr = Track()
        tr.baro = false
        tr.go(4, climb: 0, speed: 0)
        tr.baro = true
        tr.lap()
        #expect(!RunDetector.detect(tr.pts).usedGPSAltitude)
    }

    @Test func gpsOnly() {
        var tr = Track()
        tr.baro = false
        for _ in 0..<3 { tr.lap() }
        let s = RunDetector.detect(tr.pts)
        #expect(s.runs.count == 3)
        #expect(s.usedGPSAltitude)
    }

    /// 하강 중 2분 정지: 평균 속도에서 빠지고, 하강은 1회.
    @Test func stopDuringRun() {
        var tr = Track()
        tr.go(300, climb: 300, speed: 3)
        tr.go(90, climb: -150, speed: 10)
        tr.t += 120 // 멈춰 있으면 liveUpdates가 쉬어서 점이 없음
        tr.add(speed: 0)
        tr.go(90, climb: -150, speed: 10)
        let s = RunDetector.detect(tr.pts)
        #expect(s.runs.count == 1)
        #expect(abs(s.runs[0].avgSpeed - 10) < 0.3)
    }

    /// 슬로프 중간의 작은 오르막(10m)은 하강을 나누지 않는다.
    @Test func smallBumpKeepsOneRun() {
        var tr = Track()
        tr.go(300, climb: 300, speed: 3)
        tr.go(90, climb: -150, speed: 10)
        tr.go(20, climb: 10, speed: 5)
        tr.go(90, climb: -160, speed: 10)
        #expect(RunDetector.detect(tr.pts).runs.count == 1)
    }

    /// 1km 튄 점은 거리에서 빠진다.
    @Test func gpsSpikeFiltered() {
        var tr = Track()
        tr.go(300, climb: 300, speed: 3)
        tr.go(90, climb: -150, speed: 10)
        var spike = tr.pts.last!
        spike.t += 1
        spike.lat += 0.01
        tr.pts.append(spike)
        tr.go(90, climb: -150, speed: 10)
        let s = RunDetector.detect(tr.pts)
        #expect(s.runs.count == 1)
        #expect(abs(s.runs[0].distance - 1800) < 40)
    }

    /// 정확도가 나쁜 점은 버린다.
    @Test func badAccuracyDropped() {
        var tr = Track()
        tr.lap()
        for i in tr.pts.indices { tr.pts[i].hAcc = 80 }
        #expect(RunDetector.detect(tr.pts).runs.isEmpty)
    }
}

/// 06-verification 1장: Replays/의 기록 파일(R22 형식)과 기대 결과를 짝지어 확인한다.
struct ReplayTests {
    struct Expected: Decodable {
        var runs: Int
        var distance: [Double]?
        var drop: [Double]?
        var avgSpeed: [Double]?
    }

    static var files: [URL] {
        let dir = Bundle(for: Anchor.self).resourceURL!
        let all = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return all.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".expected.json") }
    }

    @Test func hasReplays() { #expect(!Self.files.isEmpty) }

    @Test(arguments: files) func replay(_ url: URL) throws {
        let file = try RecordingFile.decoder.decode(RecordingFile.self, from: Data(contentsOf: url))
        let expURL = url.deletingPathExtension().appendingPathExtension("expected.json")
        let exp = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: expURL))
        let s = RunDetector.detect(file.points, vehicle: file.vehicle.map(\.interval))
        #expect(s.runs.count == exp.runs, "\(url.lastPathComponent)")
        func within(_ v: Double, _ r: [Double]?) -> Bool { r.map { $0[0] <= v && v <= $0[1] } ?? true }
        #expect(within(s.distance, exp.distance), "distance \(s.distance)")
        #expect(within(s.drop, exp.drop), "drop \(s.drop)")
        let avg = s.runs.isEmpty ? 0 : s.runs.map(\.avgSpeed).reduce(0, +) / Double(s.runs.count)
        #expect(within(avg, exp.avgSpeed), "avgSpeed \(avg)")
    }
}

final class Anchor {}

/// `-SMDemo` 합성 기록: 12곳 모두 리프트 3번 타고 하강 3번으로 잡힌다
struct DemoSeedTests {
    @Test(arguments: Resort.all.map(\.id)) func demoRoute(resortId: String) throws {
        let map = try #require(SlopeMap.load(resortId: resortId)), terrain = try #require(Terrain.load(resortId: resortId))
        let id = UUID(), t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let pts = DemoSeed.route(map: map, terrain: terrain)
        let base = try #require(pts.first).alt
        let points = pts.enumerated().map { k, p in
            Point(id: nil, recordingId: id, t: t0.addingTimeInterval(Double(k) * 2), lat: p.lat, lon: p.lon, hAcc: 5, gpsAlt: p.alt,
                  vAcc: 5, speed: p.speed, baroAlt: p.alt - base, baroT: t0.addingTimeInterval(Double(k) * 2), seq: 0)
        }
        let s = RunDetector.detect(points, map: map)
        #expect(s.runs.count == min(3, map.lifts.count), "\(resortId) 하강 \(s.runs.count)")
    }
}
