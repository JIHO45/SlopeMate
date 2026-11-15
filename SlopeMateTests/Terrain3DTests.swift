import CoreGraphics
import Foundation
import Metal
import SceneKit
import UIKit
import Testing
import simd
@testable import SlopeMate

/// 화면용 3D 보기 순수 계산 (R50, K; 05-design 4장 "화면용 3D 보기", 06-verification R50 "3D 보기")
struct Terrain3DTests {
    static let north = 37.2, west = 128.8, step = 1.0 / 3600
    static let rows = 21, cols = 21

    /// 칸 (r, c) 중심 위경도. 소수 칸도 된다
    static func ll(_ r: Double, _ c: Double) -> (lat: Double, lon: Double) {
        (north - r * step, west + c * step)
    }

    /// 격자 칸 (r, c)에서 z(r, c) 고도인 21×21 격자
    static func grid(_ z: (Double, Double) -> Double) -> Terrain {
        Terrain(north: north, west: west, step: step, rows: rows, cols: cols,
                z: (0..<rows * cols).map { z(Double($0 / cols), Double($0 % cols)) })
    }

    /// 리프트·슬로프를 칸 좌표로 준 지도. 리프트 방향(첫 점 → 끝 점)이 위쪽
    static func map(lifts: [[(Double, Double)]], slopes: [[(Double, Double)]] = [], area: Bool = false) throws -> SlopeMap {
        func line(_ l: [(Double, Double)]) -> [[Double]] { l.map { let p = ll($0.0, $0.1); return [p.lat, p.lon] } }
        let json: [String: Any] = [
            "resort_id": "test", "source": "test", "osm_timestamp": "",
            "slopes": slopes.enumerated().map { ["id": "s\($0.offset)", "osm_ids": [], "lines": [line($0.element)], "area": area] },
            "lifts": lifts.enumerated().map { ["id": "l\($0.offset)", "osm_id": "", "kind": "chair_lift", "line": line($0.element)] },
        ]
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(SlopeMap.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// 북쪽으로 오르는 리프트(회전 0), 원점은 칸 (10, 9)
    static func northMap() throws -> SlopeMap {
        try map(lifts: [[(16, 10), (4, 10)]], slopes: [[(4, 8), (16, 8)]])
    }

    /// 행·열 방향으로 기운 평면: 1000 + 3r + 7c (삼각형 보간으로 정확)
    static func plane(_ r: Double, _ c: Double) -> Double { 1000 + 3 * r + 7 * c }

    // MARK: 좌표

    @Test func originAndScale() throws {
        let s = Terrain3D(terrain: Self.grid(Self.plane), map: try Self.northMap())
        #expect(s.angle == 0)
        let o = Self.ll(10, 9)
        #expect(abs(s.lat0 - o.lat) < 1e-9 && abs(s.lon0 - o.lon) < 1e-9)
        #expect(simd_length(s.xz(lat: o.lat, lon: o.lon)) < 1e-3)
        // 북쪽 한 칸 = −z로 30.92m, 동쪽 한 칸 = +x로 30.92·cos(위도)m
        let n = s.xz(lat: o.lat + Self.step, lon: o.lon)
        #expect(abs(n.x) < 1e-3 && abs(n.y + Float(Self.step * 111_320)) < 1e-2)
        let e = s.xz(lat: o.lat, lon: o.lon + Self.step)
        #expect(abs(e.x - Float(Self.step * cos(o.lat * .pi / 180) * 111_320)) < 1e-2 && abs(e.y) < 1e-3)
    }

    /// 화면 오른쪽 = +x, 화면 아래 = +z: MapProjection과 같은 방향·같은 비율. 리프트 위쪽이 −z
    @Test func sameDirectionAsMapProjection() throws {
        let m = try Self.map(lifts: [[(16, 3), (5, 17)]], slopes: [[(3, 4), (18, 12)]])
        let s = Terrain3D(terrain: Self.grid(Self.plane), map: m)
        #expect(abs(s.angle - MapProjection.angle(m)) < 1e-12 && s.angle != 0)
        let proj = MapProjection(m, rect: CGRect(x: 16, y: 100, width: 360, height: 500))
        let pts = [Self.ll(16, 3), Self.ll(5, 17), Self.ll(3, 4), Self.ll(18, 12), Self.ll(10, 10)]
        let a = proj.point(pts[0].lat, pts[0].lon), a3 = s.xz(lat: pts[0].lat, lon: pts[0].lon)
        var k: Double?
        for p in pts.dropFirst() {
            let b = proj.point(p.lat, p.lon), b3 = s.xz(lat: p.lat, lon: p.lon)
            let d2 = SIMD2(Double(b.x - a.x), Double(b.y - a.y)), d3 = SIMD2<Double>(Double(b3.x - a3.x), Double(b3.y - a3.y))
            let ratio = simd_length(d2) / simd_length(d3)
            if let k { #expect(abs(ratio / k - 1) < 1e-3) } else { k = ratio }
            #expect(simd_dot(simd_normalize(d2), simd_normalize(d3)) > 0.9999)
        }
        // 리프트 끝(위쪽)은 시작보다 −z
        #expect(s.xz(lat: pts[1].lat, lon: pts[1].lon).y < a3.y)
    }

    @Test func coordinateRoundTrip() throws {
        let s = Terrain3D(terrain: Self.grid(Self.plane), map: try Self.map(lifts: [[(16, 3), (5, 17)]]))
        for (r, c) in [(0.0, 0.0), (3.3, 17.8), (20, 20), (-5, 30)] {
            let p = Self.ll(r, c)
            let q = s.coordinate(s.xz(lat: p.lat, lon: p.lon))
            #expect(abs(q.lat - p.lat) < 1e-7 && abs(q.lon - p.lon) < 1e-7)
        }
    }

    // MARK: 높이·메시

    @Test func heightOnTiltedPlane() throws {
        let s = Terrain3D(terrain: Self.grid(Self.plane), map: try Self.northMap())
        #expect(s.baseHeight == 1000)
        for (r, c) in [(0.0, 0.0), (2.25, 7.5), (10.9, 3.1), (19.5, 19.5), (20, 20)] {
            let p = Self.ll(r, c)
            let want = Float(Self.plane(r, c) - 1000) * s.exaggeration
            #expect(abs(s.height(lat: p.lat, lon: p.lon) - want) < 0.01)
            #expect(abs(s.height(s.xz(lat: p.lat, lon: p.lon)) - want) < 0.01)
            let pt = s.point(lat: p.lat, lon: p.lon, lift: 2)
            #expect(abs(pt.y - want - 2) < 0.01)
        }
        // 격자 밖은 가장 가까운 가장자리 값
        let out = Self.ll(-6, 5), edge = Self.ll(0, 5)
        #expect(abs(s.height(lat: out.lat, lon: out.lon) - s.height(lat: edge.lat, lon: edge.lon)) < 0.01)
        let corner = Self.ll(30, 30), last = Self.ll(20, 20)
        #expect(abs(s.height(lat: corner.lat, lon: corner.lon) - s.height(lat: last.lat, lon: last.lon)) < 0.01)
    }

    /// 칸 안 두 삼각형이 메시와 같은 분할: (r,c)·(r+1,c)·(r,c+1) / (r,c+1)·(r+1,c)·(r+1,c+1)
    @Test func heightUsesMeshTriangles() throws {
        // (1,1)만 솟은 격자: 칸 (0,0) 안에서 a + b ≤ 1 쪽은 0, 반대쪽은 (1,1)에 비례
        let s = Terrain3D(terrain: Self.grid { $0 == 1 && $1 == 1 ? 100 : 0 }, map: try Self.northMap())
        let low = Self.ll(0.3, 0.3), high = Self.ll(0.8, 0.8)
        #expect(abs(s.height(lat: low.lat, lon: low.lon)) < 0.01)
        #expect(abs(s.height(lat: high.lat, lon: high.lon) - 100 * 0.6 * s.exaggeration) < 0.01)
    }

    /// 과장 = 1.5 × clamp(550 / 슬로프·리프트 높이 차(1.5배 기준), 1, 1.7)
    @Test func exaggerationGrowsOnLowRelief() throws {
        let m = try Self.northMap() // 점은 4~16행
        // 높이 차 12행 × 100m × 1.5 = 1800 → 1.5
        #expect(Terrain3D(terrain: Self.grid { r, _ in 100 * r }, map: m).exaggeration == 1.5)
        // 12 × 25 × 1.5 = 450 → 1.5 × 550/450
        #expect(abs(Terrain3D(terrain: Self.grid { r, _ in 25 * r }, map: m).exaggeration - 1.5 * 550 / 450) < 1e-4)
        // 12 × 3 × 1.5 = 54 → 상한 1.5 × 1.7
        let s = Terrain3D(terrain: Self.grid(Self.plane), map: m)
        #expect(abs(s.exaggeration - 2.55) < 1e-4)
        // 구도 과장한 높이로: 모든 선이 구 안
        for p in [Self.ll(16, 10), Self.ll(4, 10), Self.ll(4, 8), Self.ll(16, 8)] {
            #expect(simd_distance(s.point(lat: p.lat, lon: p.lon), s.center) <= s.radius + 0.01)
        }
    }

    @Test func meshMatchesGrid() throws {
        let s = Terrain3D(terrain: Self.grid(Self.plane), map: try Self.northMap())
        let m = s.mesh()
        let n = Self.rows * Self.cols
        #expect(m.positions.count == n && m.uv.count == n)
        #expect(m.indices.count < (Self.rows - 1) * (Self.cols - 1) * 6 && m.indices.count % 3 == 0)
        #expect(m.indices.allSatisfy { Int($0) < n })
        // 원 안쪽(edge 1)은 실제 높이. 원 반지름 = 동서 폭(경도 칸 × cos 위도)의 절반이라 동서가 좁다
        for (r, c) in [(10, 10), (7, 12), (14, 9)] {
            let p = Self.ll(Double(r), Double(c)), v = m.positions[r * Self.cols + c]
            let xz = s.xz(lat: p.lat, lon: p.lon)
            #expect(simd_distance(SIMD2(v.x, v.z), xz) < 0.01)
            #expect(abs(v.y - s.height(lat: p.lat, lon: p.lon)) < 0.01)
        }
        // 원형 가장자리: 높이 0까지 낮추고, 원 밖 정점은 원 위로. 세 정점이 모두 원 위인 삼각형은 없다
        let c0 = m.positions[10 * Self.cols + 10], R = simd_distance(SIMD2(m.positions[10 * Self.cols].x, m.positions[10 * Self.cols].z), SIMD2(c0.x, c0.z))
        func rim(_ v: SIMD3<Float>) -> Bool { simd_distance(SIMD2(v.x, v.z), SIMD2(c0.x, c0.z)) > R * 0.999 }
        #expect(m.positions.allSatisfy { simd_distance(SIMD2($0.x, $0.z), SIMD2(c0.x, c0.z)) <= R + 0.01 })
        #expect(m.positions.filter(rim).allSatisfy { abs($0.y) < 1e-3 } && rim(m.positions[0]) && rim(m.positions[n - 1]))
        #expect(stride(from: 0, to: m.indices.count, by: 3).allSatisfy { t in !(0..<3).allSatisfy { rim(m.positions[Int(m.indices[t + $0])]) } })
        // 위에서 볼 때 시계 반대: 삼각형 면 방향이 위
        for t in stride(from: 0, to: m.indices.count, by: 3 * 37) where !(0..<3).contains(where: { rim(m.positions[Int(m.indices[t + $0])]) }) {
            let a = m.positions[Int(m.indices[t])], b = m.positions[Int(m.indices[t + 1])], c = m.positions[Int(m.indices[t + 2])]
            #expect(simd_cross(b - a, c - a).y > 0)
        }
        // UV: 북서 (0, 0) … 남동 (1, 1)
        #expect(m.uv[0] == SIMD2(0, 0) && m.uv[n - 1] == SIMD2(1, 1) && m.uv[10 * Self.cols + 5] == SIMD2(0.25, 0.5))
    }

    @Test func flatMeshIsLevel() throws {
        let m = Terrain3D(terrain: Self.grid { _, _ in 700 }, map: try Self.northMap()).mesh()
        #expect(m.positions.allSatisfy { abs($0.y) < 1e-4 })
    }

    // MARK: 리본

    @Test func ribbonFollowsTerrain() throws {
        let s = Terrain3D(terrain: Self.grid(Self.plane), map: try Self.northMap())
        let line = [Self.ll(16, 10), Self.ll(4, 10)]   // 남 → 북 371m
        let r = s.ribbon(line, width: 10, lift: 2)
        // 지형 + 띄운 높이, 동서로 기운 면에서도 3D 폭 10m
        #expect(r.positions.allSatisfy { abs($0.y - s.height(SIMD2($0.x, $0.z)) - 2) < 0.01 })
        #expect(stride(from: 0, to: r.positions.count, by: 2).allSatisfy { abs(simd_distance(r.positions[$0], r.positions[$0 + 1]) - 10) < 0.01 })
        // 15m보다 긴 구간은 나뉜다: 371m / 15m → 25칸 이상
        let length = Float(12 * Self.step * 111_320)
        #expect(r.positions.count >= 2 * Int((length / 15).rounded(.up)))
        #expect(r.indices.allSatisfy { Int($0) < r.positions.count })
        #expect(r.cuts == [0, r.indices.count / 3])
        // maxStep을 키우면 덜 나뉜다
        #expect(s.ribbon(line, width: 10, lift: 2, maxStep: 1000).indices.count < r.indices.count)
    }

    @Test func ribbonCutsAndDash() throws {
        let s = Terrain3D(terrain: Self.grid(Self.plane), map: try Self.northMap())
        let line = [Self.ll(16, 2), Self.ll(10, 9), Self.ll(10.2, 9.1), Self.ll(3, 18), Self.ll(5, 18)]
        let r = s.ribbon(line, width: 6, lift: 3)
        #expect(r.cuts.count == line.count)
        #expect(r.cuts.first == 0 && r.cuts.last == r.indices.count / 3)
        #expect(zip(r.cuts, r.cuts.dropFirst()).allSatisfy { $0 <= $1 })
        let d = s.ribbon(line, width: 6, lift: 3, dash: (on: 4, off: 4))
        // 점선은 경계마다 나뉘어 15m 실선보다 삼각형이 많을 수 있다. 같은 잘게(1m) 나눈 실선과 비교하면 약 절반
        let fine = s.ribbon(line, width: 6, lift: 3, maxStep: 1)
        #expect(d.indices.count > 0 && d.indices.count < fine.indices.count * 6 / 10)
        #expect(d.cuts.count == line.count && d.cuts.last == d.indices.count / 3)
        #expect(zip(d.cuts, d.cuts.dropFirst()).allSatisfy { $0 <= $1 })
        // 점이 2개 미만이거나 모두 같은 자리(멈춘 구간)면 빈 리본, cuts는 점 수만큼 0
        for short in [[], [line[0]], [line[0], line[0]], [line[1], line[1], line[1]]] {
            let e = s.ribbon(short, width: 6, lift: 3)
            #expect(e.positions.isEmpty && e.indices.isEmpty && e.geometry() == nil)
            #expect(e.cuts == Array(repeating: 0, count: short.count))
        }
        // 같은 점이 연속으로 들어와도 리본은 이어진다
        let dup = s.ribbon([line[0], line[0], line[1], line[1], line[3]], width: 6, lift: 3)
        #expect(dup.indices.count > 0 && dup.cuts.count == 5 && dup.cuts[0] == 0 && dup.cuts[1] == 0)
        #expect(dup.cuts[2] == dup.cuts[3] && dup.cuts.last == dup.indices.count / 3)
    }

    /// 기운 면을 비스듬히 가로지르는 선: 가로 폭이 아니라 3D 폭이 width
    @Test func ribbonWidthOnTiltedPlane() throws {
        let s = Terrain3D(terrain: Self.grid { r, c in 1000 + 20 * r + 25 * c }, map: try Self.northMap())
        let r = s.ribbon([Self.ll(18, 2), Self.ll(3, 17)], width: 8, lift: 1)
        let widths = stride(from: 0, to: r.positions.count, by: 2).map { simd_distance(r.positions[$0], r.positions[$0 + 1]) }
        #expect(!widths.isEmpty && widths.allSatisfy { abs($0 - 8) < 0.08 })
        // 가로로만 재면 8보다 좁다(기운 면이라 3D 폭에 맞춰 줄였다)
        let flat = simd_distance(SIMD2(r.positions[0].x, r.positions[0].z), SIMD2(r.positions[1].x, r.positions[1].z))
        #expect(flat < 7.9)
    }

    /// Chaikin: 점 n개 → 한 번에 2n − 2개, 끝점 그대로, 입력 점 위치는 늘기만 하고 마지막 = 끝
    @Test func chaikinSmooth() {
        let p: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(100, 0), SIMD2(100, 100), SIMD2(200, 100), SIMD2(200, 0)]
        let one = Terrain3D.chaikin(p, times: 1), two = Terrain3D.chaikin(p, times: 2)
        #expect(one.points.count == 8 && two.points.count == 14)
        #expect(two.points.first == p.first && two.points.last == p.last)
        #expect(two.index.count == p.count && two.index.first == 0 && two.index.last == two.points.count - 1)
        #expect(zip(two.index, two.index.dropFirst()).allSatisfy { $0 < $1 })
        // 꺾인 점은 깎여 없어진다
        #expect(!two.points.contains(p[1]))
        #expect(Terrain3D.chaikin(p, times: 0).points == p && Terrain3D.chaikin(Array(p.prefix(2)), times: 2).points.count == 2)
    }

    /// smooth 리본: cuts는 입력 점 기준(개수, 단조, 마지막 = 삼각형 수), 삼각형은 더 많다
    @Test func ribbonSmoothKeepsCuts() throws {
        let s = Terrain3D(terrain: Self.grid(Self.plane), map: try Self.northMap())
        let line = [Self.ll(16, 2), Self.ll(10, 9), Self.ll(10.2, 9.1), Self.ll(3, 18), Self.ll(5, 18)]
        let plain = s.ribbon(line, width: 6, lift: 3, maxStep: 1000), r = s.ribbon(line, width: 6, lift: 3, maxStep: 1000, smooth: 2)
        #expect(r.cuts.count == line.count && r.cuts.first == 0 && r.cuts.last == r.indices.count / 3)
        #expect(zip(r.cuts, r.cuts.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(r.indices.count > plain.indices.count)
        #expect(s.ribbon([line[0], line[0]], width: 6, lift: 3, smooth: 2).cuts == [0, 0])
    }

    // MARK: 카메라

    static let viewport = CGSize(width: 393, height: 852)

    @Test func cameraPosition() {
        let c = Camera3D(target: SIMD3(1, 2, 3), distance: 10, yaw: .pi / 2, pitch: .pi / 6)
        let want = SIMD3<Float>(1, 2, 3) + 10 * SIMD3(cos(Float.pi / 6), sin(Float.pi / 6), 0)
        #expect(simd_distance(c.position, want) < 1e-4)
        #expect(abs(c.metersPerPoint(viewportHeight: 800) - 2 * 10 * tan(Camera3D.fovY / 2) / 800) < 1e-6)
    }

    /// 처음 시점: 2D와 같은 방향(카메라가 +z 쪽, 산 위가 화면 위), 34도, 구가 들어오는 거리
    @Test func cameraHome() throws {
        let s = Terrain3D(terrain: Self.grid(Self.plane), map: try Self.northMap())
        let h = Camera3D.home(s, viewport: Self.viewport)
        #expect(h.yaw == 0 && abs(h.pitch - 34 * .pi / 180) < 1e-5)
        #expect(abs(Camera3D.homePitch - 34 * .pi / 180) < 1e-5)
        #expect(h.position.z > h.target.z && abs(h.position.x - h.target.x) < 1e-3)
        #expect(simd_distance(SIMD2(h.target.x, h.target.z), SIMD2(s.center.x, s.center.z)) <= s.radius)
        // 구가 시야각 안: 보이는 영역이 화면보다 작으니 distance · sin(fov/2) ≥ radius
        #expect(h.distance * sin(Camera3D.fovY / 2) >= s.radius * 0.99)
        #expect(h.distance * sin(Camera3D.fovY / 2) < s.radius * 5)
    }

    @Test func cameraClamps() throws {
        let s = Terrain3D(terrain: Self.grid(Self.plane), map: try Self.northMap())
        let h = Camera3D.home(s, viewport: Self.viewport)
        var c = h
        c.pitch = 89 * .pi / 180
        #expect(abs(c.clamped(s, home: h).pitch - Camera3D.pitchRange.upperBound) < 1e-5)
        c = h; c.pitch = 5 * .pi / 180
        #expect(c.clamped(s, home: h).pitch >= Camera3D.pitchRange.lowerBound - 1e-5)
        c = h; c.distance = h.distance * 10
        #expect(abs(c.clamped(s, home: h).distance - h.distance * 1.3) < 1e-2)
        c = h; c.distance = h.distance * 0.01
        #expect(abs(c.clamped(s, home: h).distance - h.distance * 0.15) < 1e-2)
        // 목표점: 구 안, 높이는 그 자리 지형
        c = h; c.target = s.center + SIMD3(s.radius * 10, 500, -s.radius * 3)
        let t = c.clamped(s, home: h).target
        #expect(simd_distance(SIMD2(t.x, t.z), SIMD2(s.center.x, s.center.z)) <= s.radius + 0.01)
        #expect(abs(t.y - s.height(SIMD2(t.x, t.z))) < 0.01)
    }

    /// 남쪽(+z)으로 가파르게 오르는 비탈 앞에서 낮게 기울이면 지형 + 30m 위로 pitch를 올린다
    @Test func cameraStaysAboveTerrain() throws {
        let s = Terrain3D(terrain: Self.grid { r, _ in 1000 + 20 * r }, map: try Self.northMap())
        let h = Camera3D.home(s, viewport: Self.viewport)
        var c = h
        c.distance = h.distance * 0.2
        c.pitch = Camera3D.pitchRange.lowerBound
        let k = c.clamped(s, home: h)
        let p = k.position
        #expect(p.y >= s.height(SIMD2(p.x, p.z)) + 30 - 0.5)
        #expect(k.pitch > Camera3D.pitchRange.lowerBound && k.pitch <= Camera3D.pitchRange.upperBound + 1e-5)
    }

    /// 큰 격자에서 낮게 기울이면 pitch 그대로, 작은 격자면 화면 아래 땅이 가장자리 페이드 안쪽(edge 0.2)이 될 때까지 올린다(최대 34도)
    @Test func cameraKeepsGridBorderOffScreen() throws {
        let m = try Self.northMap()
        let small = Terrain3D(terrain: Self.flat, map: m)
        let h = Camera3D.home(small, viewport: Self.viewport)
        var c = h
        c.pitch = 25 * .pi / 180
        #expect(c.bottomEdge(small) < 0.2)
        let k = c.clamped(small, home: h)
        #expect(k.pitch > c.pitch && (k.bottomEdge(small) >= 0.2 || abs(k.pitch - Camera3D.homePitch) < 1e-5))
        // 처음 각도보다 높으면 그대로
        var top = h
        top.pitch = 60 * .pi / 180
        #expect(top.clamped(small, home: h).pitch == top.pitch)
        // 같은 선, 사방 200칸 넓은 격자
        let big = Terrain(north: Self.north + 200 * Self.step, west: Self.west - 200 * Self.step, step: Self.step, rows: 421, cols: 421,
                          z: Array(repeating: 1000, count: 421 * 421))
        let wide = Terrain3D(terrain: big, map: m), hw = Camera3D.home(wide, viewport: Self.viewport)
        var w = hw
        w.pitch = 25 * .pi / 180
        #expect(w.clamped(wide, home: hw).pitch == w.pitch)
    }

    // MARK: 겨울 산 질감 (3D v5)

    static let flat = grid { _, _ in 1000 }
    static func at(_ r: Int, _ c: Int) -> Int { r * cols + c }

    /// 완만히 북쪽으로 오르는 비탈(숲이 자라는 곳)
    static let hill = grid { r, _ in 1000 + 6 * (20 - r) }

    static func texelLum(_ g: Terrain3D.GroundTexture, _ i: Int, _ j: Int) -> Float {
        let k = 4 * (i * g.width + j); return (Float(g.bytes[k]) + Float(g.bytes[k + 1]) + Float(g.bytes[k + 2])) / 3
    }

    /// 질감 텍셀 (i, j)의 밝기(0~255 평균)와 가운데 장면 xz
    static func texel(_ g: Terrain3D.GroundTexture, _ s: Terrain3D, _ i: Int, _ j: Int) -> (lum: Float, xz: SIMD2<Float>) {
        let k = 4 * (i * g.width + j)
        let p = ll((Double(i) + 0.5) * Double(rows - 1) / Double(g.height), (Double(j) + 0.5) * Double(cols - 1) / Double(g.width))
        return ((Float(g.bytes[k]) + Float(g.bytes[k + 1]) + Float(g.bytes[k + 2])) / 3, s.xz(lat: p.lat, lon: p.lon))
    }

    /// 긴 변 = min(side, 16 × 격자 긴 변), 짧은 변은 m 비율(동서가 cos 위도만큼 짧다). 같은 입력이면 같은 질감
    @Test func groundTextureSize() throws {
        let m = try Self.northMap(), s = Terrain3D(terrain: Self.hill, map: m), mesh = s.mesh()
        let g = s.groundTexture(map: m, mesh: mesh)
        #expect(g.height == 21 * 16 && g.width == Int((Float(g.height) * Float(cos(s.lat0 * .pi / 180))).rounded()))
        #expect(g.bytes.count == g.width * g.height * 4 && g.image?.width == g.width)
        #expect(g.bytes == s.groundTexture(map: m, mesh: mesh).bytes)
        let small = s.groundTexture(map: m, mesh: mesh, side: 64)
        #expect(small.height == 64 && small.width < 64)
    }

    /// 캐시: 처음엔 만들어 <dir>/<리조트 ID>.rgba에 쓰고, 다음엔 읽는다. 깨진 파일은 새로 만들고, 입력이 다르면 덮어쓴다
    @Test func groundTextureCache() throws {
        let m = try Self.northMap(), s = Terrain3D(terrain: Self.hill, map: m), mesh = s.mesh()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = s.cachedGroundTexture(map: m, mesh: mesh, side: 64, dir: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["test.rgba"])
        let b = s.cachedGroundTexture(map: m, mesh: mesh, side: 64, dir: dir)
        #expect(a.bytes == b.bytes && a.width == b.width && a.bytes == s.groundTexture(map: m, mesh: mesh, side: 64).bytes)
        try Data(repeating: 0xFF, count: 40).write(to: dir.appendingPathComponent("test.rgba"))
        #expect(s.cachedGroundTexture(map: m, mesh: mesh, side: 64, dir: dir).bytes == a.bytes)
        #expect(s.cachedGroundTexture(map: m, mesh: mesh, side: 48, dir: dir).height == 48)
    }

    /// 숲 지도 파일(tools/canopy/build.py 형식)을 만든다. value(행, 열) → 0~15 또는 255
    static func canopy(k: Int = 2, extraCols: Int = 0, _ value: (Int, Int) -> UInt8) -> Terrain3D.Canopy? {
        let w = (cols - 1) * k + extraCols, h = (rows - 1) * k
        let cells = (0..<h).flatMap { r in (0..<w).map { c in value(r, c) } }
        let hw = w / k, hh = h / k   // 높이 판 hk=1, 모두 10m(5)
        guard let z = try? (Data(cells + [UInt8](repeating: 5, count: hw * hh)) as NSData).compressed(using: .zlib) as Data else { return nil }
        var d = Data("CNP2".utf8) + [UInt8(k), 1, UInt8(w & 0xFF), UInt8(w >> 8), UInt8(h & 0xFF), UInt8(h >> 8)]
        d += z
        return Terrain3D.Canopy(data: d)
    }

    /// 숲 지도 읽기: 머리·압축 왕복, 쌍선형, 범위 밖(255)은 nil, 깨진 파일은 nil
    @Test func canopyDecode() throws {
        let c = try #require(Self.canopy { _, col in col < (Self.cols - 1) ? 15 : 0 })
        #expect(c.width == (Self.cols - 1) * 2 && c.height == (Self.rows - 1) * 2)
        #expect(c.sample(10, 2) == 1 && c.sample(10, Float(Self.cols - 3)) == 0)
        #expect(c.sample(10, Float(Self.cols - 1) / 2).map { $0 > 0.3 && $0 < 0.7 } == true)   // 경계는 중간값
        #expect(Self.canopy { r, _ in r < 4 ? 255 : 15 }?.sample(1, 5) == nil)
        // 칸 가운데((i+0.5)/k)는 그 칸 값 ÷ 15(반 칸 어긋남 확인), 가장자리는 끝 칸 값
        let g = try #require(Self.canopy { r, col in UInt8((r * 3 + col) % 16) })
        for (i, j) in [(3, 5), (10, 17), (0, 0)] { #expect(abs(g.sample((Float(i) + 0.5) / 2, (Float(j) + 0.5) / 2)! - Float((i * 3 + j) % 16) / 15) < 1e-5) }
        #expect(g.sample(0, 0) == Float(0) / 15)
        #expect(Terrain3D.Canopy(data: Data("CNP2xxxxxxxx".utf8)) == nil)
        #expect(abs(g.treeHeight(5, 5) - 10) < 1e-4)
    }

    /// 숲 지도가 있으면 왼쪽 반(숲)은 어둡고 오른쪽 반(빈 땅)은 눈. 캐시 키에도 들어간다. 없으면 질감이 그대로다
    @Test func canopyForestFace() throws {
        let m = try Self.map(lifts: [], slopes: []), s = Terrain3D(terrain: Self.hill, map: m), mesh = s.mesh()
        let half = (Self.cols - 1)   // k=2 칸 기준 가운데 열
        let c = try #require(Self.canopy { _, col in col < half ? 15 : 0 })
        let g = s.groundTexture(map: m, mesh: mesh, canopy: c)
        let left = Self.texel(g, s, g.height / 2, g.width / 6).lum, right = Self.texel(g, s, g.height / 2, g.width * 5 / 6).lum
        #expect(left + 60 < right && right > 200, "숲 \(left), 빈 땅 \(right)")
        // 해는 북서쪽: 서쪽 숲(10m)의 그림자가 경계 동쪽 눈에 진다(먼 눈보다 어둡다)
        let edge = Self.texel(g, s, g.height / 2, g.width / 2 + 3).lum
        #expect(edge + 8 < right, "그림자 \(edge), 먼 눈 \(right)")
        #expect(s.groundTexture(map: m, mesh: mesh).bytes == s.groundTexture(map: m, mesh: mesh, canopy: nil).bytes)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = s.cachedGroundTexture(map: m, mesh: mesh, side: 64, dir: dir)
        let b = s.cachedGroundTexture(map: m, mesh: mesh, side: 64, canopy: c, dir: dir)
        #expect(a.bytes != b.bytes && b.bytes == s.groundTexture(map: m, mesh: mesh, side: 64, canopy: c).bytes)
        // 격자 크기가 다른 숲 파일은 무시
        let wrong = try #require(Self.canopy(extraCols: 2) { _, _ in 15 })
        #expect(s.groundTexture(map: m, mesh: mesh, side: 64, canopy: wrong).bytes == a.bytes)
        // 패치(window)도 같은 격자 위치에 경계: 경계 왼쪽은 숲, 오른쪽은 눈
        let p = s.groundTexture(map: m, mesh: mesh, side: 64, window: SIMD4(5, Float(half) / 2 - 3, 15, Float(half) / 2 + 3), canopy: c)
        let pl = Self.texelLum(p, p.height / 2, p.width / 8), pr = Self.texelLum(p, p.height / 2, p.width * 7 / 8)
        #expect(pl + 60 < pr, "패치 숲 \(pl), 눈 \(pr)")
    }

    /// 번들의 용평 숲 파일은 DEM 격자와 크기가 맞는다
    @Test func bundledCanopyMatchesDEM() throws {
        let c = try #require(Terrain3D.Canopy.load(resortId: "yongpyong"))
        let dem = try #require(Bundle.main.url(forResource: "dem-yongpyong", withExtension: "json"))
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: dem)) as! [String: Any]
        #expect(c.width == ((j["cols"] as! Int) - 1) * c.k && c.height == ((j["rows"] as! Int) - 1) * c.k)
    }

    /// 선 슬로프(반폭 20m)는 흰 눈 띠, 40~80m 떨어진 숲보다 확실히 밝다
    @Test func slopeIsWhiteBand() throws {
        let m = try Self.map(lifts: [], slopes: [[(2, 10), (18, 10)]])
        let s = Terrain3D(terrain: Self.hill, map: m), g = s.groundTexture(map: m, mesh: s.mesh())
        let a = s.xz(lat: Self.ll(2, 10).lat, lon: Self.ll(2, 10).lon), b = s.xz(lat: Self.ll(18, 10).lat, lon: Self.ll(18, 10).lon)
        var band: [Float] = [], forest: [Float] = []
        for i in g.height / 3..<g.height * 2 / 3 {
            for j in 0..<g.width {
                let (lum, v) = Self.texel(g, s, i, j)
                let t = min(max(simd_dot(v - a, b - a) / simd_length_squared(b - a), 0), 1), d = simd_distance(v, a + (b - a) * t)
                if d < 10 { band.append(lum) } else if d > 40 && d < 80 { forest.append(lum) }
            }
        }
        let mb = band.reduce(0, +) / Float(band.count), mf = forest.reduce(0, +) / Float(forest.count)
        #expect(band.count > 50 && forest.count > 200)
        #expect(mb > 200 && mb > mf * 1.6, "band \(mb) forest \(mf)")
    }

    /// 면 슬로프 안쪽은 숲 없이 고르게 흰 눈
    @Test func areaSlopeIsFilled() throws {
        let m = try Self.map(lifts: [], slopes: [[(5, 5), (5, 15), (15, 15), (15, 5), (5, 5)]], area: true)
        let s = Terrain3D(terrain: Self.hill, map: m), g = s.groundTexture(map: m, mesh: s.mesh())
        let inside = (g.height * 8 / 20..<g.height * 12 / 20).flatMap { i in (g.width * 8 / 20..<g.width * 12 / 20).map { Self.texel(g, s, i, $0).lum } }
        #expect(inside.allSatisfy { $0 > 200 })
    }

    /// 베이스 눈밭: 리프트 끝 (16, 10)과 슬로프 끝 (16, 8)은 한 묶음 → 리프트 끝 바깥(남) 25m는 눈.
    /// 진행 방향 안쪽(북 60m, 동 30m: 띠 밖)과 외딴 리프트 끝(슬로프 없음) 바깥 25m는 숲(눈보다 어둡다)
    @Test func liftStationIsSnow() throws {
        let m = try Self.northMap(), lone = try Self.map(lifts: [[(16, 10), (4, 10)]])
        let m1 = 1 / (Self.step * 111_320), cc = 30 * m1 / cos(Self.north * .pi / 180)   // 1m, 동쪽 30m = 칸 몇 개
        func patch(_ m: SlopeMap, _ r: Double, _ c: Double) -> [Float] {
            let s = Terrain3D(terrain: Self.hill, map: m), g = s.groundTexture(map: m, mesh: s.mesh())
            let p = s.xz(lat: Self.ll(r, c).lat, lon: Self.ll(r, c).lon)
            return (0..<g.height).flatMap { i in (0..<g.width).compactMap { j in let t = Self.texel(g, s, i, j); return simd_distance(t.xz, p) < 6 ? t.lum : nil } }
        }
        func mean(_ x: [Float]) -> Float { x.reduce(0, +) / Float(x.count) }
        let out = patch(m, 16 + 25 * m1, 10), inner = patch(m, 16 - 60 * m1, 10 + cc), lonely = patch(lone, 16 + 25 * m1, 10)
        #expect(out.count > 10 && out.allSatisfy { $0 > 200 }, "out min \(out.min() ?? 0)")
        #expect(mean(inner) < mean(out) - 15 && mean(lonely) < mean(out) - 15, "out \(mean(out)) inner \(mean(inner)) lone \(mean(lonely))")
    }

    /// 슬로프는 아래 끝까지 원래 폭: 슬로프 끝 (16, 8)에서 진행 방향 안쪽(북) 30m, 중심선 옆(서) 30m는 숲. 끝 바깥(남) 30m는 눈
    @Test func baseStartsBelowSlopeEnd() throws {
        let m = try Self.northMap(), s = Terrain3D(terrain: Self.hill, map: m), g = s.groundTexture(map: m, mesh: s.mesh())
        let m1 = 1 / (Self.step * 111_320), cc = 30 * m1 / cos(Self.north * .pi / 180)
        func patch(_ r: Double, _ c: Double) -> [Float] {
            let p = s.xz(lat: Self.ll(r, c).lat, lon: Self.ll(r, c).lon)
            return (0..<g.height).flatMap { i in (0..<g.width).compactMap { j in let t = Self.texel(g, s, i, j); return simd_distance(t.xz, p) < 6 ? t.lum : nil } }
        }
        func mean(_ x: [Float]) -> Float { x.reduce(0, +) / Float(x.count) }
        let out = patch(16 + 30 * m1, 8), side = patch(16 - 30 * m1, 8 - cc)
        #expect(out.count > 10 && out.allSatisfy { $0 > 200 }, "out min \(out.min() ?? 0)")
        #expect(mean(side) < mean(out) - 15, "out \(mean(out)) side \(mean(side))")
    }

    /// 베이스·정상만 눈밭: 베이스 묶음(리프트 (19, 2)…, 슬로프 (19, 0)) 리프트 끝 바깥(남) 25m는 눈,
    /// 고도 범위 중간인 중턱 묶음(리프트 끝 (10, 18), 슬로프 끝 (10, 16)) 리프트 끝 바깥 25m는 숲
    @Test func midStationIsForest() throws {
        let m = try Self.map(lifts: [[(19, 2), (1, 2)], [(10, 18), (1, 18)]], slopes: [[(1, 0), (19, 0)], [(10, 16), (19, 16)]])
        let s = Terrain3D(terrain: Self.hill, map: m), g = s.groundTexture(map: m, mesh: s.mesh()), m1 = 1 / (Self.step * 111_320)
        func patch(_ r: Double, _ c: Double) -> [Float] {
            let p = s.xz(lat: Self.ll(r, c).lat, lon: Self.ll(r, c).lon)
            return (0..<g.height).flatMap { i in (0..<g.width).compactMap { j in let t = Self.texel(g, s, i, j); return simd_distance(t.xz, p) < 6 ? t.lum : nil } }
        }
        func mean(_ x: [Float]) -> Float { x.reduce(0, +) / Float(x.count) }
        let base = patch(19 + 25 * m1, 2), mid = patch(10 + 25 * m1, 18)
        #expect(base.count > 10 && base.allSatisfy { $0 > 200 }, "base min \(base.min() ?? 0)")
        #expect(mean(mid) < mean(base) - 15, "base \(mean(base)) mid \(mean(mid))")
    }

    /// 끝점별 판정: 베이스 리프트 끝 (19, 5)에서 216m인 중턱 갈림점(짧은 리프트 위 끝 (12, 5), 슬로프 시작 (12, 6))은
    /// 베이스 묶음에 사슬로 끼지 않아 바깥(북) 25m가 숲. 베이스 끝점 (19, 5) 바깥(남) 25m는 눈
    @Test func midJunctionIsForest() throws {
        let m = try Self.map(lifts: [[(19, 2), (1, 2)], [(19, 5), (12, 5)]], slopes: [[(12, 6), (19, 6)], [(1, 0), (19, 0)]])
        let s = Terrain3D(terrain: Self.hill, map: m), g = s.groundTexture(map: m, mesh: s.mesh()), m1 = 1 / (Self.step * 111_320)
        func patch(_ r: Double, _ c: Double) -> [Float] {
            let p = s.xz(lat: Self.ll(r, c).lat, lon: Self.ll(r, c).lon)
            return (0..<g.height).flatMap { i in (0..<g.width).compactMap { j in let t = Self.texel(g, s, i, j); return simd_distance(t.xz, p) < 6 ? t.lum : nil } }
        }
        func mean(_ x: [Float]) -> Float { x.reduce(0, +) / Float(x.count) }
        let base = patch(19 + 25 * m1, 5), mid = patch(12 - 25 * m1, 5)
        #expect(base.count > 10 && base.allSatisfy { $0 > 200 }, "base min \(base.min() ?? 0)")
        #expect(mean(mid) < mean(base) - 15, "base \(mean(base)) mid \(mean(mid))")
    }

    /// 스키장 구역: 평지에서도 두 슬로프(약 150m 간격) 사이 가운데(각 띠에서 40m 넘게 떨어짐)는 숲,
    /// 슬로프에서 250m 넘게 떨어진 평지는 원래대로 트인 눈(더 밝다)
    @Test func forestBetweenSlopes() throws {
        let m = try Self.map(lifts: [], slopes: [[(2, 7), (8, 7)], [(2, 13), (8, 13)]])
        let s = Terrain3D(terrain: Self.flat, map: m), g = s.groundTexture(map: m, mesh: s.mesh())
        func patch(_ r: Double, _ c: Double) -> Float {
            let p = s.xz(lat: Self.ll(r, c).lat, lon: Self.ll(r, c).lon)
            let x = (0..<g.height).flatMap { i in (0..<g.width).compactMap { j in let t = Self.texel(g, s, i, j); return simd_distance(t.xz, p) < 20 ? t.lum : nil } }
            return x.reduce(0, +) / Float(max(x.count, 1))
        }
        let mid = patch(5, 10), far = patch(18, 10)
        #expect(mid < far - 30, "mid \(mid) far \(far)")
    }

    /// 모드 색·하늘: 밝게는 질감 그대로(1), 어둡게는 푸른 쪽으로 어둡게. 하늘 자리는 오름차순
    @Test func paletteValues() {
        let l = Terrain3D.WinterPalette(dark: false), d = Terrain3D.WinterPalette(dark: true)
        #expect(l.tintLow == SIMD3(repeating: 1) && l.tintHigh == SIMD3(repeating: 1))
        #expect(d.tintLow.z > d.tintLow.x && d.tintHigh.z > d.tintHigh.x && d.tintHigh.x > d.tintLow.x && d.tintHigh.z < 1)
        #expect(Terrain3D.skyStops == Terrain3D.skyStops.sorted() && Terrain3D.skyStops.first == 0 && Terrain3D.skyStops.last! < 1)
    }

    /// edgeScale: 격자 가로·세로 길이 ÷ 짧은 변(동서가 짧다)
    @Test func edgeScale() throws {
        let s = Terrain3D(terrain: Self.flat, map: try Self.northMap())
        #expect(s.edgeScale.x == 1 && abs(s.edgeScale.y - 1 / Float(cos(s.lat0 * .pi / 180))) < 1e-4)
    }

    /// edge: 중심에서 짧은 변 절반의 80%까지 1, 100%에서 0, 밖은 음수
    @Test func circularEdge() throws {
        let s = Terrain3D(terrain: Self.flat, map: try Self.northMap())
        let c = s.xz(lat: Self.ll(10, 10).lat, lon: Self.ll(10, 10).lon)
        let R = Float(20 * Self.step * 111_320 * cos(Self.north * .pi / 180)) / 2   // 동서가 짧은 변
        for dir in [SIMD2<Float>(1, 0), SIMD2(0, 1), simd_normalize(SIMD2<Float>(1, -1))] {
            #expect(s.edge(c) == 1 && abs(s.edge(c + dir * R * 0.8) - 1) < 1e-3)
            #expect(abs(s.edge(c + dir * R * 0.9) - 0.5) < 1e-2 && abs(s.edge(c + dir * R)) < 1e-2)
            #expect(s.edge(c + dir * R * 1.1) < 0)
        }
    }

    /// 드리운 그림자: 탑의 해 반대쪽(남동) 평지는 그늘, 해 쪽(북서) 평지는 해
    @Test func castShadow() throws {
        let m = try Self.northMap()
        let tower = Terrain3D(terrain: Self.grid { r, c in (6...8).contains(r) && (6...8).contains(c) ? 1300 : 1000 }, map: m)
        let plain = Terrain3D(terrain: Self.flat, map: m)
        #expect(tower.exaggeration == plain.exaggeration)
        let tm = tower.mesh(), sh = tower.shadow(tm)
        #expect(sh[Self.at(11, 11)] == 1 && sh[Self.at(3, 3)] == 0)
        #expect(plain.shadow(plain.mesh()).allSatisfy { $0 == 0 })
    }

    /// 골 음영: 골은 음수, 능선은 양수
    @Test func valleyIsDarker() throws {
        let m = try Self.map(lifts: [])
        // 열 방향 물결(10열 주기, 진폭 10m: 그림자 없음) + 높은 곳 눈을 막으려고 남동쪽 원 안에 높은 점(그림자는 남동쪽으로)
        func z(_ r: Double, _ c: Double, wave: Bool) -> Double {
            (r == 16 && c == 16 ? 3000 : 1000) + (wave ? 10 * cos(c * .pi / 5) : 0)
        }
        let a = Terrain3D(terrain: Self.grid { z($0, $1, wave: true) }, map: m), b = Terrain3D(terrain: Self.grid { z($0, $1, wave: false) }, map: m)
        let am = a.mesh(), ao = a.occlusion(am)
        #expect(ao[Self.at(5, 10)] > 0.1 && ao[Self.at(5, 5)] < -0.1 && ao[Self.at(5, 15)] < -0.1)
        #expect((0..<Self.cols).allSatisfy { a.shadow(am)[Self.at(5, $0)] == 0 })
        #expect(b.occlusion(b.mesh())[Self.at(5, 10)] == 0)
    }

    /// hash는 0~1
    @Test func hashRange() {
        for r in -50..<50 { for c in -50..<50 { #expect((0...1).contains(Terrain3D.hash(r, c))) } }
    }

    /// 경로 조각: 하강·리프트마다 테두리 노드 하나, 그 밖은 없음. setDark 뒤에도 진한 앞부분 범위(primitiveRange)가 그대로
    @Test @MainActor func sceneRouteNodes() throws {
        let m = try Self.northMap(), s = Terrain3D(terrain: Self.grid(Self.plane), map: m)
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        func seg(_ kind: RouteSegment.Kind, _ pts: [(Double, Double)]) -> RouteSegment {
            RouteSegment(kind: kind, points: pts.map { t += 10; let p = Self.ll($0.0, $0.1); return RoutePoint(t: t, lat: p.lat, lon: p.lon) })
        }
        let route = [seg(.lift, [(16, 10), (10, 10), (4, 10)]), seg(.run, [(4, 8), (8, 8), (12, 8), (16, 8)]), seg(.other, [(16, 8), (16, 10)])]
        let scene = Map3DScene(space: s, terrain: Map3DTerrain(space: s, map: m), map: m, route: route, dark: false, viewport: Self.viewport)
        func nodes(_ order: Int) -> [SCNNode] { scene.scene.rootNode.childNodes { n, _ in n.renderingOrder == order && n.geometry != nil } }
        #expect(nodes(3).count == 2)
        scene.setPlayback(route[1].points[2].t)
        func ranges() -> [NSRange] { nodes(5).compactMap { $0.geometry?.elements.first?.primitiveRange } }
        let before = ranges()
        #expect(before.contains { $0.length > 0 } && before != nodes(5).map { NSRange(location: 0, length: ($0.geometry?.elements.first?.primitiveCount) ?? 0) })
        scene.setDark(true)
        #expect(ranges() == before)
    }

    // MARK: 내장 데이터

    /// 내장 12곳: 리프트 과반의 위쪽 끝이 아래쪽 끝보다 높고, 모든 선이 구 안에 든다
    @Test(arguments: Resort.all.map(\.id))
    func bundledLiftsGoUp(resortId: String) throws {
        let t = try #require(Terrain.load(resortId: resortId))
        let m = try #require(SlopeMap.load(resortId: resortId))
        let s = Terrain3D(terrain: t, map: m)
        let up = m.lifts.filter { l in
            guard let a = l.line.first, let b = l.line.last else { return false }
            return s.height(lat: b[0], lon: b[1]) > s.height(lat: a[0], lon: a[1])
        }
        #expect(up.count * 2 > m.lifts.count)
        let all = m.slopes.flatMap { $0.lines.flatMap { $0 } } + m.lifts.flatMap(\.line)
        #expect(all.allSatisfy { simd_distance(s.point(lat: $0[0], lon: $0[1]), s.center) <= s.radius + 1 })
    }

    /// 가장 큰 하이원: 정점 하나씩. 시간은 기록만(Release 목표 0.5초)
    @Test func high1BuildTime() throws {
        let t = try #require(Terrain.load(resortId: "high1"))
        let m = try #require(SlopeMap.load(resortId: "high1"))
        var mesh: Terrain3D.Mesh?
        let elapsed = ContinuousClock().measure {
            mesh = Terrain3D(terrain: t, map: m).mesh()
        }
        #expect(mesh?.positions.count == t.rows * t.cols)
        print("high1 mesh \(elapsed)")   // 병렬 테스트 부하에 흔들려 단언하지 않고 기록만
    }

    /// 하이원 지형 질감(2048). 시간은 기록만(Release 목표 300ms)
    @Test func high1TextureTime() throws {
        let t = try #require(Terrain.load(resortId: "high1"))
        let m = try #require(SlopeMap.load(resortId: "high1"))
        let s = Terrain3D(terrain: t, map: m), mesh = s.mesh()
        var g: Terrain3D.GroundTexture?
        let elapsed = ContinuousClock().measure { g = s.groundTexture(map: m, mesh: mesh) }
        print("high1 texture \(elapsed)")   // 기록만(부하에 흔들린다)
        #expect(g?.height == 2048 && (g?.width ?? 0) > 1500)
    }

    // MARK: S19 고해상 패치

    /// 창(격자 일부) 질감: 긴 변 = side, 슬로프 자리는 전체 질감과 같은 자리에 같은 슬로프 색
    @Test func groundTextureWindow() throws {
        let m = try Self.northMap(), s = Terrain3D(terrain: Self.hill, map: m), mesh = s.mesh()
        let win = SIMD4<Float>(2, 4, 18, 12), g = s.groundTexture(map: m, mesh: mesh, side: 128, window: win)
        let all = s.groundTexture(map: m, mesh: mesh)
        #expect(g.height == 128 && g.width < 128)
        // 슬로프(열 8, 행 4…16) 가운데 (10, 8)의 밝기
        func lum(_ t: Terrain3D.GroundTexture, _ r: Float, _ c: Float, _ w: SIMD4<Float>) -> Int {
            let i = Int((r - w.x) / (w.z - w.x) * Float(t.height)), j = Int((c - w.y) / (w.w - w.y) * Float(t.width)), k = (i * t.width + j) * 4
            return Int(t.bytes[k]) + Int(t.bytes[k + 1]) + Int(t.bytes[k + 2])
        }
        let full = SIMD4<Float>(0, 0, 20, 20)
        #expect(abs(lum(g, 10, 8, win) - lum(all, 10, 8, full)) < 40)
        #expect(lum(g, 10, 8, win) > 600)
        // 행 방향 어긋남: 가로 슬로프(행 10)도 같은 자리
        let h = try Self.map(lifts: [[(16, 10), (4, 10)]], slopes: [[(10, 3), (10, 17)]]), sh = Terrain3D(terrain: Self.hill, map: h), hm = sh.mesh()
        let gw = sh.groundTexture(map: h, mesh: hm, side: 128, window: win), ga = sh.groundTexture(map: h, mesh: hm)
        #expect(lum(gw, 10, 6, win) > 600 && abs(lum(gw, 10, 6, win) - lum(ga, 10, 6, full)) < 40)
    }

    /// 보이는 땅의 창은 처음 시점이 맞춘 하강 점을 모두 덮는다
    @MainActor @Test func detailWindowCoversRun() throws {
        let pts = [Self.ll(14, 8), Self.ll(9, 8), Self.ll(6, 7)]
        let w = try #require(try Map3DSceneTests.scene(fitPoints: pts.map { (lat: $0.lat, lon: $0.lon) }).detailWindow())
        for (r, c) in [(14.0, 8.0), (9.0, 8.0), (6.0, 7.0)] {
            #expect(Float(r) >= w.x && Float(r) <= w.z && Float(c) >= w.y && Float(c) <= w.w)
        }
        #expect(w.x >= 0 && w.y >= 0 && w.z <= 20 && w.w <= 20)
    }
}
