import Foundation
import simd
import SceneKit

/// 화면용 3D 보기의 장면 좌표계와 지형. 값 타입, 순수 계산. 어느 스레드에서나 만든다 (R50, K; 05-design 4장 "화면용 3D 보기").
/// 단위 m. 원점은 슬로프·리프트 경계의 가운데(MapProjection과 같은 계산). MapProjection.angle로 돌린 u(화면 오른쪽)·v(화면 위)를
/// x = u, z = −v로 둔다. y = (고도 − 격자 최저) × exaggeration
nonisolated struct Terrain3D: Sendable {
    let terrain: Terrain
    /// 고도 과장 = 1.5 × clamp(550 / 슬로프·리프트 높이 차(1.5배 기준, m), 1, 1.7). 하이원·용평 1.5, 지산 2.55
    let exaggeration: Float
    /// 원점 위경도(MapProjection과 같은 계산), 회전각(MapProjection.angle), y = 0인 고도(격자 최저, m)
    let lat0, lon0, angle, baseHeight: Double
    /// 슬로프·리프트 전체를 감싸는 구 (지형 위 점들 기준). 카메라 처음 시점·제한용
    let center: SIMD3<Float>
    let radius: Float

    private static let metersPerDegree = 111_320.0
    private let kx, cosA, sinA: Double

    init(terrain: Terrain, map: SlopeMap) {
        let all = map.slopes.flatMap { $0.lines.flatMap { $0 } } + map.lifts.flatMap(\.line)
        let lats = all.map { $0[0] }, lons = all.map { $0[1] }
        let lat0 = ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2
        let lon0 = ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2
        let base = Terrain3D(terrain: terrain, lat0: lat0, lon0: lon0, angle: MapProjection.angle(map),
                             baseHeight: terrain.z.min() ?? 0, exaggeration: 1.5, center: .zero, radius: 0)
        var pts = all.map { base.point(lat: $0[0], lon: $0[1]) }
        guard let first = pts.first else { self = base; return }
        // 높이 차가 작은 리조트일수록 더 과장
        let ys = pts.map(\.y), range = ys.max()! - ys.min()!
        let k: Float = range > 1 ? min(1.7, max(1, 550 / range)) : 1
        pts = pts.map { SIMD3($0.x, $0.y * k, $0.z) }
        // 감싸는 구: 지형 위 점들의 상자 가운데, 가장 먼 점까지
        let c = (pts.reduce(first) { simd_min($0, $1) } + pts.reduce(first) { simd_max($0, $1) }) / 2
        self = Terrain3D(terrain: terrain, lat0: lat0, lon0: lon0, angle: base.angle, baseHeight: base.baseHeight,
                         exaggeration: 1.5 * k, center: c, radius: pts.map { simd_distance($0, c) }.max() ?? 0)
    }

    private init(terrain: Terrain, lat0: Double, lon0: Double, angle: Double, baseHeight: Double, exaggeration: Float,
                 center: SIMD3<Float>, radius: Float) {
        self.terrain = terrain
        self.exaggeration = exaggeration
        self.lat0 = lat0; self.lon0 = lon0; self.angle = angle; self.baseHeight = baseHeight
        self.center = center; self.radius = radius
        kx = cos(lat0 * .pi / 180); cosA = cos(angle); sinA = sin(angle)
    }

    /// 위경도 → 장면 (x, z), m
    func xz(lat: Double, lon: Double) -> SIMD2<Float> {
        let x = (lon - lon0) * kx * Self.metersPerDegree, y = (lat - lat0) * Self.metersPerDegree
        let u = x * cosA - y * sinA, v = x * sinA + y * cosA
        return SIMD2(Float(u), Float(-v))
    }

    /// 장면 (x, z) → 위경도 (xz의 역)
    func coordinate(_ xz: SIMD2<Float>) -> (lat: Double, lon: Double) {
        let u = Double(xz.x), v = -Double(xz.y)
        let x = u * cosA + v * sinA, y = -u * sinA + v * cosA
        return (lat0 + y / Self.metersPerDegree, lon0 + x / (kx * Self.metersPerDegree))
    }

    /// 지형 높이 y (과장 적용, 최저 고도 기준). 메시와 같은 삼각형 보간, 격자 밖은 가장자리 값
    func height(lat: Double, lon: Double) -> Float {
        let t = terrain
        let r = min(max((t.north - lat) / t.step, 0), Double(t.rows - 1))
        let c = min(max((lon - t.west) / t.step, 0), Double(t.cols - 1))
        let r0 = min(Int(r), t.rows - 2), c0 = min(Int(c), t.cols - 2)
        let a = r - Double(r0), b = c - Double(c0)
        let z00 = t.z[r0 * t.cols + c0], z01 = t.z[r0 * t.cols + c0 + 1]
        let z10 = t.z[(r0 + 1) * t.cols + c0], z11 = t.z[(r0 + 1) * t.cols + c0 + 1]
        let z = a + b <= 1 ? z00 + a * (z10 - z00) + b * (z01 - z00)
                           : z11 + (1 - a) * (z01 - z11) + (1 - b) * (z10 - z11)
        return Float(z - baseHeight) * exaggeration
    }

    func height(_ xz: SIMD2<Float>) -> Float {
        let c = coordinate(xz)
        return height(lat: c.lat, lon: c.lon)
    }

    /// 장면 (x, z)의 가장자리 값(원형): 격자 중심에서의 수평 거리 ÷ (격자 짧은 변 길이의 절반)이 0.8 → 1.0일 때 1 → 0, 그 밖은 음수
    func edge(_ xz: SIMD2<Float>) -> Float {
        let (c, R) = edgeCircle
        return min(1, (1 - simd_distance(xz, c) / R) / 0.2)
    }

    /// 격자 중심(장면 xz)과 짧은 변 길이의 절반(m)
    private var edgeCircle: (SIMD2<Float>, Float) {
        let t = terrain, m = t.step * Self.metersPerDegree
        let c = xz(lat: t.north - Double(t.rows - 1) / 2 * t.step, lon: t.west + Double(t.cols - 1) / 2 * t.step)
        return (c, max(1e-3, Float(min(Double(t.rows - 1) * m, Double(t.cols - 1) * m * kx)) / 2))
    }

    /// UV 공간의 원형 가장자리: edge = clamp((1 − 2·|(uv − 0.5) × edgeScale|) ÷ 0.2, 0, 1). edgeScale = 격자 가로·세로 길이(m) ÷ 짧은 변 (셰이더용)
    var edgeScale: SIMD2<Float> {
        let t = terrain, m = t.step * Self.metersPerDegree
        let s = SIMD2(Float(Double(t.cols - 1) * m * kx), Float(Double(t.rows - 1) * m))
        return s / max(1e-3, s.min())
    }

    /// 지형 위 점. lift: 지형 위로 띄우는 높이(m)
    func point(lat: Double, lon: Double, lift: Float = 0) -> SIMD3<Float> {
        let p = xz(lat: lat, lon: lon)
        return SIMD3(p.x, height(lat: lat, lon: lon) + lift, p.y)
    }

    struct Mesh: Sendable {
        var positions: [SIMD3<Float>]   // rows × cols, 행 우선(북쪽 행부터)
        var uv: [SIMD2<Float>]          // (열 / (cols − 1), 행 / (rows − 1)). 지형 질감용
        var indices: [UInt32]           // 삼각형. 원 밖 삼각형은 빠져 (rows − 1)(cols − 1) × 6보다 적다
    }

    /// 칸 중심마다 정점 하나. 칸마다 (r,c)·(r+1,c)·(r,c+1)과 (r,c+1)·(r+1,c)·(r+1,c+1) (위에서 볼 때 시계 반대).
    /// 원형 가장자리(edge 1 → 0)에서 높이를 y × smoothstep(0, 1, edge)로 0(격자 최저)까지 낮추고, 원 밖 정점은 원 위로 당기고, 세 정점이 모두 원 위·밖인 삼각형은 뺀다.
    /// 원 밖 산이 안개색 실루엣으로 하늘에 걸리지 않게. height()는 낮추지 않은 실제 지형
    func mesh() -> Mesh {
        let t = terrain, rows = t.rows, cols = t.cols
        var positions = [SIMD3<Float>](), uv = [SIMD2<Float>]()
        positions.reserveCapacity(rows * cols); uv.reserveCapacity(rows * cols)
        let (ec, R) = edgeCircle
        for r in 0..<rows {
            for c in 0..<cols {
                let p = xz(lat: t.north - Double(r) * t.step, lon: t.west + Double(c) * t.step)
                positions.append(SIMD3(p.x, Float(t.z[r * cols + c] - baseHeight) * exaggeration * Self.smooth(0, 1, edge(p)), p.y))
                uv.append(SIMD2(Float(c) / Float(max(1, cols - 1)), Float(r) / Float(max(1, rows - 1))))
            }
        }
        // 원 밖 정점은 원 위로 당겨 테두리를 매끈한 원으로
        var inside = [Bool](repeating: true, count: rows * cols)
        for k in positions.indices {
            let p = SIMD2(positions[k].x, positions[k].z), d = simd_distance(p, ec)
            guard d >= R else { continue }
            inside[k] = false
            let q = ec + (p - ec) * (R / d)
            positions[k] = SIMD3(q.x, positions[k].y, q.y)
        }
        var indices = [UInt32]()
        indices.reserveCapacity((rows - 1) * (cols - 1) * 6)
        for r in 0..<rows - 1 {
            for c in 0..<cols - 1 {
                let i00 = UInt32(r * cols + c), i01 = i00 + 1, i10 = i00 + UInt32(cols), i11 = i10 + 1
                for tri in [[i00, i10, i01], [i01, i10, i11]] where tri.contains(where: { inside[Int($0)] }) { indices += tri }
            }
        }
        return Mesh(positions: positions, uv: uv, indices: indices)
    }

    struct Ribbon: Sendable {
        var positions: [SIMD3<Float>]
        var indices: [UInt32]           // 삼각형, 입력 순서대로
        var cuts: [Int]                 // cuts[i] = 입력 점 i까지 그릴 때의 삼각형 수. 개수는 입력 점 수, 마지막 = indices.count / 3
    }

    /// 공중 리프트 케이블(지지점 장면 좌표, 아래→위). 견인식·매직카펫 등 지면형은 nil(지면을 따라 그린다).
    /// 승·하차장은 지면 + stationHeight, 지주는 지면 + pylonHeight(m, 고도 과장 배율을 곱함). 지지점 사이 직선이
    /// 지면에서 clearance 안으로 내려가면(지주 누락·지주 데이터 없음) 가장 낮은 곳에, maxSpanHeight보다 높이 뜨면 가장 높은 곳에
    /// 지주 높이 지지점을 더한다(지주 데이터가 없는 리프트는 양 끝에서 시작해 이것만으로 세운다)
    static let aerialKinds: Set<String> = ["chair_lift", "gondola", "cable_car", "mixed_lift"]
    static let maxSpanHeight: Float = 50
    /// 지주 높이는 실제(10~20m)보다 높게 잡는다: 실제 높이로는 지도 축척에서 지면 선과 구분되지 않는다(2026-11-16 시뮬레이터)
    static let stationHeight: Float = 4, pylonHeight: Float = 20, cableClearance: Float = 4

    func cable(_ lift: SlopeMap.Lift) -> [SIMD3<Float>]? {
        guard Self.aerialKinds.contains(lift.kind), let a = lift.line.first, let b = lift.line.last, lift.line.count >= 2 else { return nil }
        let pylons = lift.pylons ?? []
        func at(_ p: SIMD2<Float>, _ up: Float) -> SIMD3<Float> { SIMD3(p.x, height(p) + up * exaggeration, p.y) }
        var sup = [at(xz(lat: a[0], lon: a[1]), Self.stationHeight)]
            + pylons.map { at(xz(lat: $0[0], lon: $0[1]), Self.pylonHeight) }
            + [at(xz(lat: b[0], lon: b[1]), Self.stationHeight)]
        var i = 0
        while i + 1 < sup.count, sup.count < 200 {
            let p = sup[i], q = sup[i + 1], len = simd_distance(SIMD2(p.x, p.z), SIMD2(q.x, q.z))
            var worst: (gap: Float, t: Float)?, highest: (gap: Float, t: Float)?
            for k in stride(from: Float(10), to: len, by: 10) {
                let t = k / len, m = p + (q - p) * t
                let gap = m.y - height(SIMD2(m.x, m.z))
                if gap < Self.cableClearance * exaggeration, gap < (worst?.gap ?? .infinity) { worst = (gap, t) }
                if gap > Self.maxSpanHeight * exaggeration, gap > (highest?.gap ?? -.infinity) { highest = (gap, t) }
            }
            worst = worst ?? highest
            if let w = worst {
                let m = p + (q - p) * w.t
                sup.insert(at(SIMD2(m.x, m.z), Self.pylonHeight), at: i + 1)
            } else { i += 1 }
        }
        return sup
    }

    /// 지주 기둥: 케이블 지지점(양 끝 승·하차장 제외)마다 지면에서 케이블까지 십자로 엇갈린 세로 판 두 장(어느 방향에서도 보이게). width는 m
    func pylons(_ cable: [SIMD3<Float>], width: Float) -> Ribbon {
        var r = Ribbon(positions: [], indices: [], cuts: [])
        let h = width / 2
        for top in cable.dropFirst().dropLast() {
            let y0 = height(SIMD2(top.x, top.z))
            for d in [SIMD3<Float>(h, 0, 0), SIMD3<Float>(0, 0, h)] {
                let b = UInt32(r.positions.count)
                r.positions += [SIMD3(top.x, y0, top.z) - d, SIMD3(top.x, y0, top.z) + d, top - d, top + d]
                r.indices += [b, b + 1, b + 2, b + 2, b + 1, b + 3]
            }
        }
        return r
    }

    /// xz에서 within m 안의 가장 가까운 케이블 높이(구간에 투영해 직선 보간). 없으면 nil
    static func cableHeight(_ cables: [[SIMD3<Float>]], at p: SIMD2<Float>, within: Float = 60) -> Float? {
        var best: (d: Float, y: Float)?
        for c in cables {
            for (a, b) in zip(c, c.dropFirst()) {
                let a2 = SIMD2(a.x, a.z), ab = SIMD2(b.x, b.z) - a2
                let t = min(max(simd_dot(p - a2, ab) / max(simd_length_squared(ab), 1e-6), 0), 1)
                let d = simd_distance(p, a2 + ab * t)
                if d <= within, d < (best?.d ?? .infinity) { best = (d, a.y + (b.y - a.y) * t) }
            }
        }
        return best?.y
    }

    /// 위경도 선 → 지형 위 리본. width·lift·dash·maxStep은 m. dash가 있으면 on만큼 그리고 off만큼 비운다. 점이 2개 미만이거나 모두 같은 자리면 빈 리본.
    /// smooth: Chaikin 횟수(경로만 2). cuts는 입력 점 기준 그대로. 리본 3D 폭은 어디서나 width(기운 면에서도)
    /// heightAt: 지면 대신 쓸 높이(공중 케이블). nil을 돌려주는 곳과 주지 않으면 지면 + lift
    func ribbon(_ line: [(lat: Double, lon: Double)], width: Float, lift: Float,
                dash: (on: Float, off: Float)? = nil, maxStep: Float = 15, smooth: Int = 0,
                heightAt: ((SIMD2<Float>) -> Float?)? = nil) -> Ribbon {
        guard line.count >= 2 else { return Ribbon(positions: [], indices: [], cuts: line.isEmpty ? [] : [0]) }
        let (pts, inputAt) = Self.chaikin(line.map { xz(lat: $0.lat, lon: $0.lon) }, times: smooth)
        let period = dash.map { $0.on + $0.off } ?? 0
        let usesDash = dash != nil && period > 0, on = dash?.on ?? 0

        // 표본: 위치, 다음 구간을 그리는지, 입력 점 i가 놓인 표본(길이 0 구간이면 앞 점과 같은 표본)
        var samples: [SIMD2<Float>] = [pts[0]], drawNext: [Bool] = [], sampleOf = [0]
        var s: Float = 0 // 선을 따라 잰 거리
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i], len = simd_distance(a, b)
            if len > 1e-4 {
                let n = max(1, Int((len / max(maxStep, 0.01)).rounded(.up)))
                var ts = (1...n).map { Float($0) / Float(n) * len }
                if usesDash, let dash {
                    // 이 구간 안의 점선 경계
                    var k = (s / period).rounded(.down)
                    while k * period < s + len {
                        for e in [k * period, k * period + dash.on] where e > s && e < s + len { ts.append(e - s) }
                        k += 1
                    }
                    ts.sort()
                }
                var prev: Float = 0
                for t in ts where t - prev > 1e-4 {
                    let mid = s + (prev + t) / 2
                    drawNext.append(!usesDash || mid - (mid / period).rounded(.down) * period < on)
                    samples.append(a + (b - a) * (t / len))
                    prev = t
                }
                s += len
            }
            sampleOf.append(samples.count - 1)
        }
        // 모든 점이 같은 자리(멈춘 구간)
        guard samples.count >= 2 else { return Ribbon(positions: [], indices: [], cuts: Array(repeating: 0, count: line.count)) }

        // 표본마다 양쪽 가장자리 정점(이웃 구간 방향의 평균에 수직, 꺾인 곳은 최대 2배까지 넓힌다).
        // 지형 위에 올린 두 정점 l·r을 가운데 m에서 3D 거리 half × 꺾임 배율로 다시 놓는다(옆으로 기운 면에서 폭이 늘지 않게)
        let half = width / 2
        var positions = [SIMD3<Float>](), indices = [UInt32](), trianglesAt = [Int]()
        func side(_ d: SIMD2<Float>) -> SIMD2<Float> { SIMD2(-d.y, d.x) }
        for k in samples.indices {
            let din = k > 0 ? simd_normalize(samples[k] - samples[k - 1]) : nil
            let dout = k + 1 < samples.count ? simd_normalize(samples[k + 1] - samples[k]) : nil
            let nin = din.map(side), nout = dout.map(side)
            var n = simd_normalize((nin ?? nout!) + (nout ?? nin!))
            if !n.x.isFinite { n = nout ?? nin! } // 되돌아가는 선
            let scale = min(2, 1 / max(0.5, simd_dot(n, nout ?? nin!)))
            let air = heightAt?(samples[k])   // 공중이면 가운데 높이 하나로(양쪽이 수평)
            let e = [samples[k] + n * half * scale, samples[k] - n * half * scale].map { SIMD3($0.x, air ?? height($0) + lift, $0.y) }
            let m = (e[0] + e[1]) / 2
            for v in e { positions.append(simd_length(v - m) > 1e-6 ? m + simd_normalize(v - m) * half * scale : v) }
            if k > 0, drawNext[k - 1] {
                let l0 = UInt32(2 * (k - 1)), r0 = l0 + 1, l1 = l0 + 2, r1 = l0 + 3
                indices += [l0, r0, l1, l1, r0, r1]
            }
            trianglesAt.append(indices.count / 3)
        }
        return Ribbon(positions: positions, indices: indices, cuts: inputAt.map { trianglesAt[sampleOf[$0]] })
    }

    /// 끝점을 둔 Chaikin 깎기 times번. 한 번에 점 n개 → 2n − 2개(p0, R0, Q1, R1, …, Q(n−2), p(n−1)).
    /// index[i] = 입력 점 i가 놓인 출력 점(꺾인 곳 앞의 R, 끝점은 끝점). 늘기만 하고 마지막 = 출력 개수 − 1
    static func chaikin(_ p: [SIMD2<Float>], times: Int) -> (points: [SIMD2<Float>], index: [Int]) {
        var pts = p, index = Array(p.indices)
        guard p.count > 2 else { return (pts, index) }
        for _ in 0..<max(0, times) {
            var out = [pts[0]]
            out.reserveCapacity(2 * pts.count - 2)
            for i in 0..<pts.count - 1 {
                let a = pts[i], b = pts[i + 1]
                if i > 0 { out.append(a * 0.75 + b * 0.25) }
                if i < pts.count - 2 { out.append(a * 0.25 + b * 0.75) }
            }
            out.append(pts[pts.count - 1])
            pts = out
            index = index.map { max(0, 2 * $0 - 1) }
        }
        return (pts, index)
    }
}

// MARK: 겨울 산 질감 (3D v5)

nonisolated extension Terrain3D {
    /// 해 방향(빛이 오는 쪽, 해 높이 35도). 처음 시점의 화면 왼쪽 위. 질감 음영에 굽는다
    static let sun = simd_normalize(SIMD3<Float>(-0.58, 0.57, -0.58))
    /// 선 슬로프 눈 띠 반폭(m)과 가장자리 부드러움(±m), 리프트 길 반폭·부드러움
    static let slopeHalf: Float = 20, slopeSoft: Float = 6, liftHalf: Float = 6, liftSoft: Float = 3
    /// 베이스·정상 눈밭(m): 끝점 덩어리 반지름·바깥으로 민 거리, 잇는 띠 반폭, 묶는 거리, 부드러운 합 폭, 가장자리 흔들림(±)·숲으로 넘어가는 폭
    static let baseRadius: Float = 50, basePush: Float = 30, baseBand: Float = 34, baseJoin: Float = 250
    static let baseBlend: Float = 13, baseWobble: Float = 12, baseFade: Float = 14
    /// 방향 페이드(m): 끝점에서 바깥쪽 거리 s가 baseBack 이하면 눈밭 없음, baseFront 이상이면 그대로. 슬로프 쪽으로 넓어지지 않게
    static let baseBack: Float = -5, baseFront: Float = 15
    /// 눈밭 후보 끝점: 고도가 끝점 고도 범위의 아래 이 비율 안(베이스)이나 위 이 비율 안(정상). 중턱 승하차장·갈림점은 그리지 않는다
    static let baseLevel: Float = 0.15
    /// 같은 종류 후보끼리 묶는 고도 차 한도(끝점 고도 범위에 대한 비율)
    static let baseRise: Float = 0.07
    /// 스키장 구역(m): 슬로프(선·면 테두리)·리프트 선까지 거리 zoneNear 안은 자연 빈터(평지·능선·급사면·잡음 개활지) 없이 숲,
    /// zoneFar 밖은 원래 규칙, 사이는 부드럽게. 거리는 zoneCell 간격 거친 격자에서 구해 겹선형으로 읽는다
    static let zoneNear: Float = 150, zoneFar: Float = 250, zoneCell: Float = 25

    /// 하늘 그라데이션 자리(화면 위 0 … 아래 1): 맨 위, 하늘, 지평 안개, 땅 안개. 배경 이미지와 지형 셰이더가 같이 쓴다
    static let skyStops: [Float] = [0, 0.3, 0.5, 0.85]

    /// 모드별 색. sRGB 0~1 (05-design 4장 "3D v5")
    struct WinterPalette: Sendable {
        /// 하늘 맨 위, 하늘, 지평 안개, 땅 안개(화면 아래 원 밖)
        let skyTop, skyMid, haze, ground: SIMD3<Float>
        /// 질감에 곱하는 색(선형 밝기 0 쪽, 1 쪽). 밝게는 1
        let tintLow, tintHigh: SIMD3<Float>
        init(dark: Bool) {
            func c(_ l: UInt32, _ d: UInt32) -> SIMD3<Float> { Terrain3D.rgb(dark ? d : l) }
            skyTop = c(0x8FBDE4, 0x1C2A44); skyMid = c(0xC9DFF0, 0x4A6189)
            haze = c(0xE2ECF3, 0x6A7FA3); ground = c(0x8796A2, 0x26344D)
            tintLow = dark ? SIMD3(0.34, 0.42, 0.66) : SIMD3(repeating: 1)
            tintHigh = dark ? SIMD3(0.50, 0.60, 0.86) : SIMD3(repeating: 1)
        }
    }

    /// 질감 바탕색(sRGB). 밝게·어둡게 같은 질감
    enum Ground {
        static let snow: UInt32 = 0xF2F6F9, slope: UInt32 = 0xFBFCFE, floor: UInt32 = 0x7A8896
        static let conifer: UInt32 = 0x223F33, broadleaf: UInt32 = 0x6E655F
        /// 숲 지도가 있는 곳의 숲 면(청록 회색)
        static let forestFace: UInt32 = 0x6A8088
    }

    static func rgb(_ v: UInt32) -> SIMD3<Float> {
        SIMD3(Float(v >> 16 & 0xFF), Float(v >> 8 & 0xFF), Float(v & 0xFF)) / 255
    }

    /// 정수 해시, 0~1
    static func hash(_ r: Int, _ c: Int) -> Float {
        var x = UInt32(truncatingIfNeeded: r) &* 73_856_093 ^ UInt32(truncatingIfNeeded: c) &* 19_349_663
        x ^= x >> 13; x &*= 0x5bd1_e995; x ^= x >> 15
        return Float(x & 0xFFFF) / 65535
    }

    /// 값 잡음 0~1 (정수 격자 해시를 smoothstep으로 잇는다)
    static func noise(_ x: Float, _ y: Float, _ seed: Int) -> Float {
        let xf = x.rounded(.down), yf = y.rounded(.down), xi = Int(xf) &+ seed &* 7_919, yi = Int(yf)
        let u = x - xf, v = y - yf, su = u * u * (3 - 2 * u), sv = v * v * (3 - 2 * v)
        let a = hash(yi, xi), b = hash(yi, xi + 1), c = hash(yi + 1, xi), d = hash(yi + 1, xi + 1)
        return (a + (b - a) * su) * (1 - sv) + (c + (d - c) * su) * sv
    }

    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }

    /// sRGB → 선형
    static func linear(_ v: SIMD3<Float>) -> SIMD3<Float> {
        func f(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return SIMD3(f(v.x), f(v.y), f(v.z))
    }

    /// 드리운 그림자 0(해) … 1(그늘). 칸에서 해의 수평 방향으로 한 칸씩 최대 48칸 걸으며 (그 칸 높이 − 내 높이) ÷ 수평 거리의 최댓값 t,
    /// smoothstep(0, 0.3, t − tan 35도). 높이는 과장 적용 값(메시 y), 격자 밖에서 멈춘다
    func shadow(_ mesh: Mesh) -> [Float] {
        let t = terrain, rows = t.rows, cols = t.cols
        guard mesh.positions.count == rows * cols, rows > 1, cols > 1 else { return Array(repeating: 0, count: mesh.positions.count) }
        let h = mesh.positions.map(\.y)
        // 해의 수평 방향 = a × (행 한 칸) + b × (열 한 칸). 큰 쪽이 한 칸이 되게 맞춘다
        let o = xz(lat: t.north, lon: t.west)
        let er = xz(lat: t.north - t.step, lon: t.west) - o, ec = xz(lat: t.north, lon: t.west + t.step) - o
        let d = simd_normalize(SIMD2(Self.sun.x, Self.sun.z)), det = er.x * ec.y - ec.x * er.y
        let a0 = (d.x * ec.y - ec.x * d.y) / det, b0 = (er.x * d.y - d.x * er.y) / det
        let a = a0 / max(abs(a0), abs(b0)), b = b0 / max(abs(a0), abs(b0))
        let len = simd_length(er * a + ec * b)
        let tanSun: Float = 0.70, maxR = Float(rows - 1), maxC = Float(cols - 1)
        var out = [Float](repeating: 0, count: rows * cols)
        out.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let out = out
            DispatchQueue.concurrentPerform(iterations: rows) { r in
                for c in 0..<cols {
                    let h0 = h[r * cols + c]
                    var best = -Float.infinity
                    for s in 1...48 {
                        let fr = Float(r) + a * Float(s), fc = Float(c) + b * Float(s)
                        guard fr >= 0, fc >= 0, fr <= maxR, fc <= maxC else { break }
                        let r0 = min(Int(fr), rows - 2), c0 = min(Int(fc), cols - 2)
                        let u = fr - Float(r0), v = fc - Float(c0), i = r0 * cols + c0
                        let hs = (h[i] * (1 - v) + h[i + 1] * v) * (1 - u) + (h[i + cols] * (1 - v) + h[i + cols + 1] * v) * u
                        best = max(best, (hs - h0) / (Float(s) * len))
                        if best >= tanSun + 0.3 { break }
                    }
                    out[r * cols + c] = Self.smooth(0, 0.3, best - tanSun)
                }
            }
        }
        return out
    }

    /// 골 음영 −1(골) … 1(능선) = clamp((내 높이 − 7×7칸 평균 높이) ÷ 60m, −1, 1). 높이는 과장 적용 값, 격자 끝은 안쪽 칸만 평균
    func occlusion(_ mesh: Mesh) -> [Float] {
        let rows = terrain.rows, cols = terrain.cols
        guard mesh.positions.count == rows * cols else { return Array(repeating: 0, count: mesh.positions.count) }
        var sum = [Double](repeating: 0, count: (rows + 1) * (cols + 1))
        for r in 0..<rows {
            var acc = 0.0
            for c in 0..<cols {
                acc += Double(mesh.positions[r * cols + c].y)
                sum[(r + 1) * (cols + 1) + c + 1] = sum[r * (cols + 1) + c + 1] + acc
            }
        }
        var out = [Float](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            let r0 = max(0, r - 3), r1 = min(rows, r + 4)
            for c in 0..<cols {
                let c0 = max(0, c - 3), c1 = min(cols, c + 4)
                let s = sum[r1 * (cols + 1) + c1] - sum[r0 * (cols + 1) + c1] - sum[r1 * (cols + 1) + c0] + sum[r0 * (cols + 1) + c0]
                let mean = Float(s / Double((r1 - r0) * (c1 - c0)))
                out[r * cols + c] = min(max((mesh.positions[r * cols + c].y - mean) / 60, -1), 1)
            }
        }
        return out
    }

    /// 지형 질감(3D v5). RGBA 8비트 sRGB, 첫 행이 북쪽, 메시 UV(Mesh.uv)로 격자 전체를 덮는다.
    /// 긴 변 = min(side, 16 × 격자 긴 변 칸 수), 짧은 변은 격자 가로·세로 길이(m) 비율. 텍셀 (i, j) 가운데 = 격자 ((i + 0.5)(rows − 1) / H, (j + 0.5)(cols − 1) / W).
    /// 높이는 Catmull-Rom(bicubic)으로 올려 법선을 텍셀마다 구한다(각진 음영 없음). 그림자·골 음영은 격자 값(shadow, occlusion)을 겹선형으로.
    /// 숲(침엽·활엽 나무 점묘, 나무 그림자) / 눈(높은 능선, 낮은 평지, 급사면: 스키장 구역 밖만) / 슬로프(선은 반폭 20m ± 6m, 면은 안쪽 + 6m) / 리프트 길(반폭 6m ± 3m) 위에
    /// 해 방향 고정 음영을 굽는다. 모드 색과 원형 가장자리·안개는 셰이더(Map3DScene)
    struct GroundTexture: Sendable {
        let width, height: Int
        /// RGBA, width × height × 4
        let bytes: Data

        var image: CGImage? {
            guard let provider = CGDataProvider(data: bytes as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                           decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// 질감 만드는 방식(색·폭·나무 등)을 바꾸면 올린다. 캐시 키에 들어간다
    static let textureVersion: UInt64 = 14

    static let textureCacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("terrain3d", isDirectory: true)

    /// groundTexture를 <dir>/<리조트 ID>.rgba 하나에 둔다(RGBA 다음 끝 16바이트: 키 UInt64, 너비·높이 UInt32, 리틀 엔디언).
    /// 키 = 입력(회전각, 과장, 기준 고도, 격자, 슬로프·리프트 좌표, side, textureVersion)의 FNV-1a 64. 키가 다르거나 읽기에 실패하면 새로 만들어 덮어쓴다
    func cachedGroundTexture(map: SlopeMap, mesh: Mesh, side: Int = 2048, canopy: Canopy? = nil, dir: URL = Self.textureCacheDir) -> GroundTexture {
        var key: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ v: UInt64) { key = (key ^ v) &* 0x100_0000_01b3 }
        mix(canopy?.key ?? 0)
        for v in [Self.textureVersion, UInt64(side), UInt64(terrain.rows), UInt64(terrain.cols), UInt64(exaggeration.bitPattern)] { mix(v) }
        // 회전각: 해 방향이 장면 기준이라 각이 바뀌면 음영도 바뀐다
        for v in [angle, baseHeight, terrain.north, terrain.west, terrain.step] + terrain.z { mix(v.bitPattern) }
        for s in map.slopes {
            mix(s.area == true ? 1 : 2)
            for l in s.lines { mix(UInt64(l.count)); for p in l { for x in p { mix(x.bitPattern) } } }
        }
        for l in map.lifts { mix(UInt64(l.line.count)); for p in l.line { for x in p { mix(x.bitPattern) } } }
        let url = dir.appendingPathComponent(map.resortId + ".rgba")
        if let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 16 {
            let t = d.count - 16
            let k = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: t, as: UInt64.self).littleEndian }
            let w = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: t + 8, as: UInt32.self).littleEndian })
            let h = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: t + 12, as: UInt32.self).littleEndian })
            if k == key, w <= 4096, h <= 4096, t == w * h * 4 { return GroundTexture(width: w, height: h, bytes: d.prefix(t)) }
        }
        let g = groundTexture(map: map, mesh: mesh, side: side, canopy: canopy)
        var d = g.bytes
        withUnsafeBytes(of: key.littleEndian) { d.append(contentsOf: $0) }
        for v in [UInt32(g.width), UInt32(g.height)] { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
        return g
    }

    /// 앱용 숲 지도(tools/canopy/build.py). 출처 Meta·WRI 나무 높이 지도 v2(CC BY 4.0)를 가공:
    /// 숲 비율 판 = DEM 격자를 k배로 나눈 칸(용평 k=10, 약 3m)의 높이 4m 이상 비율 0~15(범위 밖 255),
    /// 나무 높이 판 = DEM 격자를 hk배로 나눈 칸(약 15m)의 숲 평균 높이 ÷ 2m(0~15).
    /// 파일 maps/canopy-<리조트>.bin = "CNP2" + k + hk + 숲 판 너비·높이(UInt16 LE) + raw DEFLATE(숲 판 + 높이 판)
    struct Canopy: Sendable {
        let k: Int, width: Int, height: Int, cells: [UInt8], key: UInt64
        let hk: Int, hWidth: Int, hHeight: Int, heights: [UInt8]

        init?(data d: Data) {
            guard d.count > 10, d.prefix(4) == Data("CNP2".utf8) else { return nil }
            let k = Int(d[d.startIndex + 4]), hk = Int(d[d.startIndex + 5])
            let w = Int(d[d.startIndex + 6]) | Int(d[d.startIndex + 7]) << 8, h = Int(d[d.startIndex + 8]) | Int(d[d.startIndex + 9]) << 8
            guard k > 0, hk > 0, w % k == 0, h % k == 0, w > 1, h > 1 else { return nil }
            let hw = w / k * hk, hh = h / k * hk
            guard hw > 1, hh > 1, let raw = try? (d.dropFirst(10) as NSData).decompressed(using: .zlib) as Data, raw.count == w * h + hw * hh else { return nil }
            var key: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in d { key = (key ^ UInt64(b)) &* 0x100_0000_01b3 }
            self.k = k; width = w; height = h; cells = [UInt8](raw.prefix(w * h)); self.key = key
            self.hk = hk; hWidth = hw; hHeight = hh; heights = [UInt8](raw.suffix(hw * hh))
        }

        static func load(resortId: String, bundle: Bundle = .main) -> Canopy? {
            bundle.url(forResource: "canopy-\(resortId)", withExtension: "bin").flatMap { try? Data(contentsOf: $0) }.flatMap(Canopy.init(data:))
        }

        /// 격자 좌표(행, 열)의 숲 비율 0~1(쌍선형, 가장자리는 끝 칸으로). 네 칸 중 하나라도 범위 밖(255)이면 nil
        func sample(_ r: Float, _ c: Float) -> Float? { cells.withUnsafeBufferPointer { Self.sample($0, k, width, height, r, c) } }

        /// 격자 좌표의 나무 높이(m, 쌍선형)
        func treeHeight(_ r: Float, _ c: Float) -> Float { heights.withUnsafeBufferPointer { Self.treeHeight($0, hk, hWidth, hHeight, r, c) } }
        static func treeHeight(_ p: UnsafeBufferPointer<UInt8>, _ k: Int, _ w: Int, _ h: Int, _ r: Float, _ c: Float) -> Float {
            let y = min(max(r * Float(k) - 0.5, 0), Float(h - 1)), x = min(max(c * Float(k) - 0.5, 0), Float(w - 1))
            let y0 = min(Int(y), h - 2), x0 = min(Int(x), w - 2), u = y - Float(y0), v = x - Float(x0), i = y0 * w + x0
            return 2 * ((Float(p[i]) * (1 - v) + Float(p[i + 1]) * v) * (1 - u) + (Float(p[i + w]) * (1 - v) + Float(p[i + w + 1]) * v) * u)
        }

        /// 병렬 구간용: 배열 대신 포인터로 읽는다(참조 계수 경합 없음)
        static func sample(_ p: UnsafeBufferPointer<UInt8>, _ k: Int, _ w: Int, _ h: Int, _ r: Float, _ c: Float) -> Float? {
            let y = min(max(r * Float(k) - 0.5, 0), Float(h - 1)), x = min(max(c * Float(k) - 0.5, 0), Float(w - 1))
            let y0 = min(Int(y), h - 2), x0 = min(Int(x), w - 2), u = y - Float(y0), v = x - Float(x0)
            let i = y0 * w + x0, a = p[i], b = p[i + 1], c2 = p[i + w], d = p[i + w + 1]
            guard a != 255, b != 255, c2 != 255, d != 255 else { return nil }
            return ((Float(a) * (1 - v) + Float(b) * v) * (1 - u) + (Float(c2) * (1 - v) + Float(d) * v) * u) / 15
        }
    }

    /// window: 격자 (행0, 열0, 행1, 열1) 안만 side 해상도로 그린다(S19 고해상 패치). 이때 나무는 7m 칸에 별 모양 수관·긴 그림자. nil이면 격자 전체.
    /// canopy: 있으면 그 범위 안 숲은 실제 숲 비율로 칠한 면(나무 도장·절차적 빈터 없음). 밖은 원래 규칙
    func groundTexture(map: SlopeMap, mesh: Mesh, side: Int = 2048, window: SIMD4<Float>? = nil, canopy: Canopy? = nil) -> GroundTexture {
        let t = terrain, rows = t.rows, cols = t.cols
        let win = window ?? SIMD4(0, 0, Float(rows - 1), Float(cols - 1))
        // 숲 지도는 이 DEM 격자와 크기가 맞을 때만(DEM을 다시 만들면 숲 파일도 다시)
        let canopy = canopy.flatMap { $0.width == (cols - 1) * $0.k && $0.height == (rows - 1) * $0.k ? $0 : nil }
        let (ck, cw, ch) = (canopy?.k ?? 1, canopy?.width ?? 2, canopy?.height ?? 2), canopyCells = canopy?.cells ?? []
        let (hk, hw, hh) = (canopy?.hk ?? 1, canopy?.hWidth ?? 2, canopy?.hHeight ?? 2), canopyHeights = canopy?.heights ?? []
        let cell = t.step * Self.metersPerDegree
        let wm = Float(Double(win.w - win.y) * cell * kx), hm = Float(Double(win.z - win.x) * cell)
        let long = window == nil ? max(2, min(side, 16 * max(rows, cols))) : side
        let W = wm >= hm ? long : max(2, Int((Float(long) * wm / hm).rounded()))
        let H = wm >= hm ? max(2, Int((Float(long) * hm / wm).rounded())) : long
        let sr = (win.z - win.x) / Float(H), sc = (win.w - win.y) / Float(W)   // 텍셀 한 칸 = 격자 몇 칸
        // 텍셀 (i, j) → 장면 xz는 아핀
        let la0 = t.north - Double(win.x) * t.step, lo0 = t.west + Double(win.y) * t.step, p0 = xz(lat: la0, lon: lo0)
        let di = (xz(lat: la0 - t.step, lon: lo0) - p0) * sr, dj = (xz(lat: la0, lon: lo0 + t.step) - p0) * sc
        let o = p0 + (di + dj) / 2, pr = simd_length(di), pc = simd_length(dj)

        // 1. 높이(과장 적용, Catmull-Rom 가로 → 세로)
        let zf = t.z.map { Float($0 - baseHeight) * exaggeration }
        func taps(_ x: Float, _ n: Int) -> (SIMD4<Int>, SIMD4<Float>) {
            let i = Int(x.rounded(.down)), f = x - Float(i), f2 = f * f, f3 = f2 * f
            let w = SIMD4(-f3 + 2 * f2 - f, 3 * f3 - 5 * f2 + 2, -3 * f3 + 4 * f2 + f, f3 - f2) / 2
            return (SIMD4(i - 1, i, i + 1, i + 2).clamped(lowerBound: .zero, upperBound: SIMD4(repeating: n - 1)), w)
        }
        let colTaps = (0..<W).map { taps(win.y + (Float($0) + 0.5) * sc, cols) }, rowTaps = (0..<H).map { taps(win.x + (Float($0) + 0.5) * sr, rows) }
        var across = [Float](repeating: 0, count: rows * W)
        for r in 0..<rows {
            for j in 0..<W {
                let (k, w) = colTaps[j], b = r * cols
                across[r * W + j] = zf[b + k[0]] * w[0] + zf[b + k[1]] * w[1] + zf[b + k[2]] * w[2] + zf[b + k[3]] * w[3]
            }
        }
        let up = across
        var hgt = [Float](repeating: 0, count: W * H)
        hgt.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let out = out
            DispatchQueue.concurrentPerform(iterations: H) { i in
                let (k, w) = rowTaps[i]
                for j in 0..<W {
                    out[i * W + j] = up[k[0] * W + j] * w[0] + up[k[1] * W + j] * w[1] + up[k[2] * W + j] * w[2] + up[k[3] * W + j] * w[3]
                }
            }
        }

        // 2. 슬로프·리프트 자리(0 숲 … 1 깨끗한 눈)
        var clear = [Float](repeating: 0, count: W * H)
        func texel(_ p: [Double]) -> SIMD2<Float> { SIMD2((Float((t.north - p[0]) / t.step) - win.x) / sr - 0.5, (Float((p[1] - t.west) / t.step) - win.y) / sc - 0.5) }
        func stroke(_ line: [[Double]], half: Float, soft: Float, amount: Float) {
            guard line.count >= 2 else { return }
            let g = line.map(texel), pts = line.map { xz(lat: $0[0], lon: $0[1]) }
            let pad = SIMD2((half + soft) / pr + 1, (half + soft) / pc + 1)
            for k in 1..<line.count {
                let lo = simd_min(g[k - 1], g[k]) - pad, hi = simd_max(g[k - 1], g[k]) + pad
                let i0 = max(0, Int(lo.x.rounded(.down))), i1 = min(H - 1, Int(hi.x.rounded(.up)))
                let j0 = max(0, Int(lo.y.rounded(.down))), j1 = min(W - 1, Int(hi.y.rounded(.up)))
                guard i0 <= i1, j0 <= j1 else { continue }
                let a = pts[k - 1], ab = pts[k] - a, len2 = max(simd_length_squared(ab), 1e-6)
                for i in i0...i1 {
                    let row = o + di * Float(i)
                    for j in j0...j1 {
                        let v = row + dj * Float(j), s = min(max(simd_dot(v - a, ab) / len2, 0), 1)
                        let c = amount * (1 - Self.smooth(half - soft, half + soft, simd_distance(v, a + ab * s)))
                        if c > clear[i * W + j] { clear[i * W + j] = c }
                    }
                }
            }
        }
        for s in map.slopes {
            guard s.area == true else { for l in s.lines { stroke(l, half: Self.slopeHalf, soft: Self.slopeSoft, amount: 1) }; continue }
            // 면: 테두리 바깥으로 6m 부드럽게, 안쪽은 홀짝 주사선으로 채운다(모든 고리)
            for l in s.lines { stroke(l, half: Self.slopeSoft, soft: Self.slopeSoft, amount: 1) }
            let rings = s.lines.filter { $0.count > 2 }.map { $0.map(texel) }
            let all = rings.flatMap { $0 }
            guard let first = all.first else { continue }
            let lo = all.reduce(first, simd_min), hi = all.reduce(first, simd_max)
            let i0 = max(0, Int(lo.x.rounded(.up))), i1 = min(H - 1, Int(hi.x.rounded(.down)))
            guard i0 <= i1 else { continue }
            for i in i0...i1 {
                let y = Float(i)
                var xs: [Float] = []
                for ring in rings {
                    for n in ring.indices {
                        let a = ring[n], b = ring[(n + 1) % ring.count]
                        if (a.x > y) != (b.x > y) { xs.append(a.y + (y - a.x) * (b.y - a.y) / (b.x - a.x)) }
                    }
                }
                xs.sort()
                for p in stride(from: 0, to: xs.count - 1, by: 2) {
                    let j0 = max(0, Int(xs[p].rounded(.up))), j1 = min(W - 1, Int(xs[p + 1].rounded(.down)))
                    if j0 <= j1 { for j in j0...j1 { clear[i * W + j] = 1 } }
                }
            }
        }
        // 리프트 길 눈은 지면형(견인식·매직카펫)만. 공중 리프트는 숲 위를 지나기도 해 근거 없이 숲을 비우지 않는다
        // (실제 벌목 통로는 숲 지도가 있는 리조트에서 숲 지도로 나타난다. 리프트 위치는 공중 케이블·지주로 보인다)
        for l in map.lifts where !Self.aerialKinds.contains(l.kind) { stroke(l.line, half: Self.liftHalf, soft: Self.liftSoft, amount: 0.9) }
        // 베이스·정상 눈밭: 리프트 끝점과 baseJoin 안의 끝점(선 슬로프·리프트)을 묶는다. 묶음의 끝점마다 바깥쪽(끝점 − 직전 점)으로
        // basePush 밀어 둔 반지름 baseRadius 눈 덩어리, 이웃 덩어리 중심끼리(최소 신장 트리) 반폭 baseBand 띠. 덩어리·띠는 끝점 기준
        // 바깥 방향 거리 baseBack…baseFront에서 켜져 슬로프 쪽으로 넘어오지 않는다(슬로프는 끝까지 원래 폭). 부드러운 합(baseBlend)에
        // 잡음(±baseWobble)으로 가장자리와 방향 경계를 흔들고 폭 baseFade에 걸쳐 숲으로 넘어간다. 외딴 끝은 칠하지 않는다.
        // 슬로프 끝점끼리는 묶지 않는다(산 중턱 갈림길이 줄줄이 이어져 숲이 통째로 지워지지 않게).
        // 판정은 끝점별: 고도가 끝점 고도 범위 [lo, hi]의 아래·위 baseLevel 안인 끝점만 베이스·정상 후보.
        // 후보가 아닌 끝점은 덩어리도 없고 묶음에도 끼지 않는다(사슬이 끊긴다). 같은 종류 후보끼리, 고도 차 baseRise 안일 때만 묶는다
        let det0 = di.x * dj.y - dj.x * di.y
        func toTexel(_ v: SIMD2<Float>) -> SIMD2<Float> {
            let d = v - o
            return SIMD2((d.x * dj.y - dj.x * d.y) / det0, (di.x * d.y - d.x * di.y) / det0)
        }
        struct End { let p, out: SIMD2<Float>; let z: Float }
        func ends(_ line: [[Double]]) -> [End] {
            let q = line.map { xz(lat: $0[0], lon: $0[1]) }
            guard q.count >= 2 else { return [] }
            return [(q[0], q[1]), (q[q.count - 1], q[q.count - 2])].compactMap { p, prev in
                simd_distance(p, prev) > 0.1 ? End(p: p, out: simd_normalize(p - prev), z: height(p)) : nil
            }
        }
        func smin(_ a: Float, _ b: Float) -> Float {
            let k = Self.baseBlend, h = max(k - abs(a - b), 0) / k
            return min(a, b) - h * h * k / 4
        }
        func fill(_ group: [End]) {
            let R = Self.baseRadius, c = group.map { $0.p + $0.out * Self.basePush }
            // 최소 신장 트리(Prim): 밀어 둔 덩어리 중심끼리. 띠의 페이드는 양끝 w를 띠 위치로 보간
            var bands: [(Int, Int)] = [], inTree = [true] + Array(repeating: false, count: c.count - 1)
            for _ in 1..<c.count {
                var best = (Float.infinity, 0, 0)
                for a in c.indices where inTree[a] { for b in c.indices where !inTree[b] && simd_distance(c[a], c[b]) < best.0 { best = (simd_distance(c[a], c[b]), a, b) } }
                inTree[best.2] = true
                bands.append((best.1, best.2))
            }
            let reach = R + Self.baseWobble + Self.baseFade
            let g = c.map(toTexel), pad = SIMD2(reach / pr + 1, reach / pc + 1)
            let lo = g.reduce(g[0], simd_min) - pad, hi = g.reduce(g[0], simd_max) + pad
            let i0 = max(0, Int(lo.x.rounded(.down))), i1 = min(H - 1, Int(hi.x.rounded(.up)))
            let j0 = max(0, Int(lo.y.rounded(.down))), j1 = min(W - 1, Int(hi.y.rounded(.up)))
            guard i0 <= i1, j0 <= j1 else { return }
            // 방향 페이드 벌점: 끝점 안쪽(슬로프 쪽)은 거리에 (1 − w) × cut을 더해 지운다. s를 잡음으로 흔들어 경계가 곧지 않게
            let cut = reach + R
            var w = [Float](repeating: 0, count: c.count)
            for i in i0...i1 {
                for j in j0...j1 {
                    let v = o + di * Float(i) + dj * Float(j)
                    let n = 0.65 * Self.noise(v.x / 45, v.y / 45, 11) + 0.35 * Self.noise(v.x / 17, v.y / 17, 12)
                    let wob = (n - 0.5) * 2 * Self.baseWobble
                    for k in c.indices { w[k] = Self.smooth(Self.baseBack, Self.baseFront, simd_dot(v - group[k].p, group[k].out) + wob) }
                    var d = Float.infinity
                    for k in c.indices { d = smin(d, simd_distance(v, c[k]) - R + (1 - w[k]) * cut) }
                    for (a, b) in bands {
                        let pa = c[a], pb = c[b], ab = pb - pa, s = min(max(simd_dot(v - pa, ab) / max(simd_length_squared(ab), 1e-6), 0), 1)
                        d = smin(d, simd_distance(v, pa + ab * s) - Self.baseBand + (1 - (w[a] + (w[b] - w[a]) * s)) * cut)
                    }
                    guard d < Self.baseWobble + Self.baseFade else { continue }
                    d += wob
                    let cover = 1 - Self.smooth(-Self.baseFade / 2, Self.baseFade / 2, d)
                    if cover > clear[i * W + j] { clear[i * W + j] = cover }
                }
            }
        }
        let liftEnds = map.lifts.flatMap { ends($0.line) }
        let all = liftEnds + map.slopes.filter { $0.area != true }.flatMap { $0.lines.flatMap(ends) }
        var root = Array(all.indices)
        func find(_ x: Int) -> Int { var x = x; while root[x] != x { root[x] = root[root[x]]; x = root[x] }; return x }
        let zs = all.map(\.z), lo = zs.min() ?? 0, hi = zs.max() ?? 0, band = (hi - lo) * Self.baseLevel
        // 종류: 0 베이스, 1 정상, nil 후보 아님
        let kind = all.map { $0.z <= lo + band ? 0 : $0.z >= hi - band ? 1 : nil as Int? }, rise = (hi - lo) * Self.baseRise
        for a in liftEnds.indices where kind[a] != nil {
            for b in all.indices where b != a && kind[b] == kind[a] && abs(all[a].z - all[b].z) <= rise
                && simd_distance(all[a].p, all[b].p) < Self.baseJoin { root[find(a)] = find(b) }
        }
        for group in Dictionary(grouping: all.indices, by: find).values where group.count > 1 { fill(group.map { all[$0] }) }

        // 2b. 스키장 구역(0 밖 … 1 안): 거친 격자 (a, b) = 텍셀 (a·q, b·q)에서 슬로프·리프트 선분까지 최소 거리
        let q = max(1, Int((Self.zoneCell / min(pr, pc)).rounded())), zr = H / q + 2, zc = W / q + 2
        var zone = [Float](repeating: .infinity, count: zr * zc)
        let zpad = SIMD2(Self.zoneFar / (pr * Float(q)) + 1, Self.zoneFar / (pc * Float(q)) + 1)
        for line in map.slopes.flatMap(\.lines) + map.lifts.map(\.line) where line.count >= 2 {
            let pts = line.map { xz(lat: $0[0], lon: $0[1]) }, g = pts.map { toTexel($0) / Float(q) }
            for k in 1..<pts.count {
                let lo = simd_min(g[k - 1], g[k]) - zpad, hi = simd_max(g[k - 1], g[k]) + zpad
                let i0 = max(0, Int(lo.x.rounded(.down))), i1 = min(zr - 1, Int(hi.x.rounded(.up)))
                let j0 = max(0, Int(lo.y.rounded(.down))), j1 = min(zc - 1, Int(hi.y.rounded(.up)))
                guard i0 <= i1, j0 <= j1 else { continue }
                let a = pts[k - 1], ab = pts[k] - a, len2 = max(simd_length_squared(ab), 1e-6)
                for i in i0...i1 {
                    let row = o + di * Float(i * q)
                    for j in j0...j1 {
                        let v = row + dj * Float(j * q), s = min(max(simd_dot(v - a, ab) / len2, 0), 1)
                        zone[i * zc + j] = min(zone[i * zc + j], simd_distance(v, a + ab * s))
                    }
                }
            }
        }
        for k in zone.indices { zone[k] = 1 - Self.smooth(Self.zoneNear, Self.zoneFar, zone[k]) }

        // 3. 텍셀마다 색
        // 격자 칸마다 (그림자, 골 음영)
        let shade = zip(shadow(mesh), occlusion(mesh)).map { SIMD2($0, $1) }
        let top = max(mesh.positions.lazy.map(\.y).max() ?? 1, 1)
        // 해의 수평 방향(텍셀 i, j 단위)
        let s2 = simd_normalize(SIMD2(Self.sun.x, Self.sun.z)), det = di.x * dj.y - dj.x * di.y
        let sunPx = simd_normalize(SIMD2((s2.x * dj.y - dj.x * s2.y) / det, (di.x * s2.y - s2.x * di.y) / det))
        let snow = Self.linear(Self.rgb(Ground.snow)), slope = Self.linear(Self.rgb(Ground.slope)), floor = Self.linear(Self.rgb(Ground.floor))
        let conifer = Self.linear(Self.rgb(Ground.conifer)), broadleaf = Self.linear(Self.rgb(Ground.broadleaf))
        let forestFace = Self.linear(Self.rgb(Ground.forestFace))
        let tanSun = Self.sun.y / simd_length(SIMD2(Self.sun.x, Self.sun.z))
        let sky = SIMD3<Float>(0.55, 0.62, 0.78), sunC = SIMD3<Float>(0.95, 0.90, 0.84)
        // 선형 → sRGB 표(4096칸)
        let lut: [UInt8] = (0..<4096).map { k in
            let x = Float(k) / 4095
            return UInt8(min(255, max(0, (x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055) * 255 + 0.5)))
        }
        // 나무: 3텍셀(패치는 7m) 칸마다 하나. 칸마다 가운데(텍셀)·반지름과 있을 확률·활엽 문턱을 미리 구한다
        let detail = window != nil, cs: Float = detail ? max(3, 7 / min(pr, pc)) : 3, cr = Int((Float(H) / cs).rounded(.up)) + 4, cc = Int((Float(W) / cs).rounded(.up)) + 4
        var trees = [SIMD3<Float>](repeating: .zero, count: cr * cc), treeKind = [SIMD2<Float>](repeating: .zero, count: cr * cc)
        for ci in 0..<cr {
            for cj in 0..<cc {
                let a = ci - 2, b = cj - 2
                let center = (SIMD2(Float(a), Float(b)) + 0.15 + 0.7 * SIMD2(Self.hash(a &+ 17, b), Self.hash(a, b &+ 31))) * cs
                trees[ci * cc + cj] = SIMD3(center.x, center.y, cs * (0.46 + 0.26 * Self.hash(a &+ 5, b &+ 9)))
                treeKind[ci * cc + cj] = SIMD2(Self.hash(a, b &+ 50_021), Self.hash(a &+ 3, b &+ 77))
            }
        }
        let meters = SIMD2(pr, pc)
        // 병렬 구간에서 읽기만 하는 상수로(var를 붙잡으면 접근마다 배타 검사가 붙어 느리다)
        var bytes = [UInt8](repeating: 255, count: W * H * 4)
        // 병렬 구간은 포인터로만 읽는다(여러 스레드가 같은 배열을 붙잡으면 참조 계수 경합으로 몇 배 느려진다)
        hgt.withUnsafeBufferPointer { heights in clear.withUnsafeBufferPointer { cleared in zone.withUnsafeBufferPointer { zone in
        trees.withUnsafeBufferPointer { cells in treeKind.withUnsafeBufferPointer { kinds in canopyCells.withUnsafeBufferPointer { canopyPtr in canopyHeights.withUnsafeBufferPointer { heightPtr in
        shade.withUnsafeBufferPointer { shade in lut.withUnsafeBufferPointer { lut in
        bytes.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let (heights, cleared, zone, cells, kinds, shade, lut, out, canopyPtr, heightPtr) = (heights, cleared, zone, cells, kinds, shade, lut, out, canopyPtr, heightPtr)
            let hasCanopy = canopy != nil
            func grid(_ r: Float, _ c: Float) -> SIMD2<Float> {
                guard shade.count == rows * cols else { return .zero }
                let r0 = min(Int(r), rows - 2), c0 = min(Int(c), cols - 2), u = r - Float(r0), v = c - Float(c0), k = r0 * cols + c0
                return (shade[k] * (1 - v) + shade[k + 1] * v) * (1 - u) + (shade[k + cols] * (1 - v) + shade[k + cols + 1] * v) * u
            }
            DispatchQueue.concurrentPerform(iterations: H) { i in
                let gr = win.x + (Float(i) + 0.5) * sr, iu = max(0, i - 1), id = min(H - 1, i + 1)
                for j in 0..<W {
                    let k = i * W + j, h = heights[k]
                    let jl = max(0, j - 1), jr = min(W - 1, j + 1)
                    let ri = SIMD3(di.x, (heights[id * W + j] - heights[iu * W + j]) / Float(id - iu), di.y)
                    let rj = SIMD3(dj.x, (heights[i * W + jr] - heights[i * W + jl]) / Float(jr - jl), dj.y)
                    let n = simd_normalize(simd_cross(ri, rj)), ndl = max(0, simd_dot(n, Self.sun))
                    let gc = win.y + (Float(j) + 0.5) * sc
                    let g = grid(gr, gc), sh = g.x, ao = g.y
                    // 잔 골: 5텍셀 떨어진 네 점 평균보다 낮으면 어둡게
                    let a5 = max(0, i - 5), b5 = min(H - 1, i + 5), c5 = max(0, j - 5), d5 = min(W - 1, j + 5)
                    let fine = min(max((h - (heights[a5 * W + j] + heights[b5 * W + j] + heights[i * W + c5] + heights[i * W + d5]) / 4) / 6, -1), 1)
                    // 숲 밀도: 낮은 평지·높은 능선·급사면은 눈, 잡음으로 성긴 곳. 스키장 구역(z) 안은 이 빈터를 끈다
                    let m = (SIMD2(win.x, win.y) / SIMD2(sr, sc) + SIMD2(Float(i), Float(j))) * meters
                    let nl = Self.noise(m.y / 420, m.x / 420, 1), nm = Self.noise(m.y / 110, m.x / 110, 2)
                    let rel = h / top
                    let zi = Float(i) / Float(q), zj = Float(j) / Float(q), z0 = Int(zi), z1 = Int(zj), zu = zi - Float(z0), zv = zj - Float(z1), zk = z0 * zc + z1
                    let z = (zone[zk] * (1 - zv) + zone[zk + 1] * zv) * (1 - zu) + (zone[zk + zc] * (1 - zv) + zone[zk + zc + 1] * zv) * zu
                    let field = Self.smooth(0.985, 0.997, n.y) * (1 - Self.smooth(0.15, 0.3, rel + 0.1 * (nl - 0.5))) * (1 - z)
                    let ridge = Self.smooth(0.86, 0.97, rel + 0.12 * (nl - 0.5) + 0.05 * ao) * (1 - z)
                    let steep = Self.smooth(0.62, 0.5, n.y) * (1 - z)
                    let c = cleared[k]
                    // 최대 0.8: 빽빽한 숲(하이원)도 나무 사이로 눈이 비친다
                    var density = 0.8 * (z + (1 - z) * Self.smooth(0.08, 0.3, 0.55 * nm + 0.45 * nl))
                    density *= (1 - 0.85 * field) * (1 - 0.9 * ridge) * (1 - 0.7 * steep) * (1 - c)
                    if hasCanopy, let cf = Self.Canopy.sample(canopyPtr, ck, cw, ch, gr, gc) {
                        // 숲 면: 실제 숲 비율을 경계로. 키 큰 숲은 어둡게, 해 쪽 8m 앞뒤 나무 높이 차로 굴곡, 9m 잡음으로 수관 결
                        func at(_ d: Float) -> (f: Float, h: Float) {
                            let o = sunPx * (d / min(pr, pc)), r = gr + o.x * sr, cc = gc + o.y * sc
                            let s2 = Self.Canopy.sample(canopyPtr, ck, cw, ch, r, cc) ?? 0
                            return (s2, Self.Canopy.treeHeight(heightPtr, hk, hw, hh, r, cc) * Self.smooth(0.3, 0.7, s2))
                        }
                        // OSM 슬로프 띠로 비우지 않는다(중심선이 어긋나면 실제 숲을 지운다). 트인 곳은 숲 지도가 정한다
                        let f = Self.smooth(0.35, 0.65, cf)
                        let hgt = Self.Canopy.treeHeight(heightPtr, hk, hw, hh, gr, gc)
                        let relief = min(max((at(8).h - at(-8).h) * 0.025, -0.2), 0.2)
                        let grain = Self.noise(m.y / 9, m.x / 9, 5)
                        let tone = (1.08 - 0.22 * Self.smooth(8, 24, hgt)) * (0.86 + 0.14 * nm + 0.16 * grain) * (1 + relief)
                        // 숲 그림자: 해 쪽 d m에 높이 d·tan(해 고도)보다 큰 숲이 있으면 눈 위에 그림자(2m 간격)
                        var fsh: Float = 0
                        if f < 0.98 {
                            for d: Float in stride(from: 2, through: 30, by: 2) {   // 촘촘히: 성기면 작은 군락 그림자가 계단·점선으로 끊긴다
                                let s2 = at(d)
                                // 멀수록 옅게: 긴 그림자가 군락 사이 눈을 다 덮으면 군락이 한 덩어리로 읽힌다
                                fsh = max(fsh, Self.smooth(d * tanSun - 3, d * tanSun + 3, s2.h) * Self.smooth(0.2, 0.6, s2.f) * (1 - d / 40))
                            }
                        }
                        var albedo = simd_mix(simd_mix(snow, slope, SIMD3(repeating: c)), forestFace * tone, SIMD3(repeating: f))
                        albedo *= 1 - 0.42 * fsh * (1 - f)
                        let col = albedo * (sky * (0.8 + 0.25 * ao + 0.15 * fine) + sunC * (ndl * (1 - 0.75 * sh)))
                        for ch in 0..<3 { out[4 * k + ch] = lut[Int(min(max(col[ch], 0), 1) * 4095)] }
                        continue
                    }
                    // 땅: 숲 바닥(그늘진 눈) ↔ 트인 눈 ↔ 슬로프
                    var albedo = simd_mix(snow, floor, SIMD3(repeating: density * 0.7))
                    albedo = simd_mix(albedo, slope, SIMD3(repeating: c))
                    // 나무(밀도 확률): 지름 2.8~4.3텍셀, 해 쪽이 밝고 해 반대쪽에 그림자
                    let p = SIMD2(Float(i) + 0.5, Float(j) + 0.5)
                    let bi = Int(p.x / cs) + 2, bj = Int(p.y / cs) + 2, reach = detail ? 2 : 1   // 패치의 긴 그림자는 두 칸까지
                    var cover: Float = 0, shade: Float = 0, lit: Float = 0, leafKey: Float = 1
                    if density > 0.003 {
                        for ci in bi - reach...bi + reach {
                            for cj in bj - reach...bj + reach {
                                let kind = kinds[ci * cc + cj]
                                guard kind.x < density else { continue }
                                let tr = cells[ci * cc + cj], center = SIMD2(tr.x, tr.y), radius = tr.z
                                let d = p - center, len = simd_length(d)
                                if detail, len > radius * 3.7 + 1 { continue }   // 수관·그림자(2.6r 뒤 0.75r)가 닿지 않는 나무
                                var edge = radius
                                if detail, len < radius * 1.3 + 1 {
                                    // 위에서 본 침엽수: 가지 끝이 들쭉날쭉한 별 모양
                                    let phase = kind.y * 40
                                    edge = radius * (0.8 + 0.14 * cos(9 * atan2(d.y, d.x) + phase) + 0.06 * cos(5 * atan2(d.y, d.x) - phase))
                                }
                                let cv = min(max(edge + 0.5 - len, 0), 1)
                                if detail {
                                    // 그림자: 해 반대쪽으로 길게(경사 시점에서 줄기·높이가 보이게)
                                    let a = center, b = center - sunPx * radius * 2.6, ab = b - a
                                    let s = min(max(simd_dot(p - a, ab) / simd_length_squared(ab), 0), 1)
                                    shade = max(shade, min(max(radius * (0.75 - 0.35 * s) + 0.5 - simd_distance(p, a + ab * s), 0), 1))
                                } else {
                                    shade = max(shade, min(max(radius * 1.05 + 0.5 - simd_distance(p, center - sunPx * radius * 1.2), 0), 1))
                                }
                                if cv > cover {
                                    cover = cv
                                    lit = simd_dot(d, sunPx) / radius
                                    // 가운데(꼭대기)가 밝고 층마다 결
                                    if detail { lit += 0.35 * (1 - len / radius) - 0.25 + 0.12 * cos(len / radius * 13) }
                                    leafKey = kind.y
                                }
                            }
                        }
                    }
                    albedo *= 1 - 0.5 * shade * (1 - cover)
                    // 활엽(회갈색) 비율 12~42%, 낮은 곳에 많다
                    let leaf = cover > 0 && leafKey < 0.12 + 0.3 * Self.smooth(0.45, 0.75, Self.noise(m.y / 260, m.x / 260, 3)) * (1 - Self.smooth(0.3, 0.7, rel))
                    let crown = (leaf ? broadleaf : conifer) * (0.8 + 0.35 * lit)
                    albedo = simd_mix(albedo, crown, SIMD3(repeating: cover * (leaf ? 0.75 : 1)))
                    // 빛: 하늘(골 음영) + 해(그림자)
                    let ambient = sky * (0.8 + 0.25 * ao + 0.15 * fine)
                    let light = ambient + sunC * (ndl * (1 - 0.75 * sh))
                    let col = albedo * light
                    for ch in 0..<3 { out[4 * k + ch] = lut[Int(min(max(col[ch], 0), 1) * 4095)] }
                }
            }
        }}}}}}}}}}
        return GroundTexture(width: W, height: H, bytes: Data(bytes))
    }
}

nonisolated extension Terrain3D.Mesh {
    /// 위치·UV 소스와 삼각형 요소 하나(음영은 질감에 구워 법선은 넣지 않는다). 재질은 붙이지 않는다
    func geometry() -> SCNGeometry {
        SCNGeometry(sources: [Self.source(positions, .vertex, 3), Self.source(uv, .texcoord, 2)],
                    elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// Float 성분 SIMD 배열 → 소스. stride는 타입 그대로(SIMD3<Float>는 16바이트)
    static func source<T>(_ v: [T], _ semantic: SCNGeometrySource.Semantic, _ components: Int) -> SCNGeometrySource {
        let data = v.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data, semantic: semantic, vectorCount: v.count, usesFloatComponents: true,
                                 componentsPerVector: components, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<T>.stride)
    }
}

nonisolated extension Terrain3D.Ribbon {
    /// 위치 소스와 삼각형 요소 하나(법선 없음: 단색 재질용). 빈 리본이면 nil
    func geometry() -> SCNGeometry? {
        guard !indices.isEmpty else { return nil }
        return SCNGeometry(sources: [Terrain3D.Mesh.source(positions, .vertex, 3)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// 여러 리본을 한 지오메트리로(슬로프 전체, 리프트 전체). cuts는 버린다
    static func geometry(_ ribbons: [Terrain3D.Ribbon]) -> SCNGeometry? {
        var all = Terrain3D.Ribbon(positions: [], indices: [], cuts: [])
        for r in ribbons {
            let base = UInt32(all.positions.count)
            all.positions += r.positions
            all.indices += r.indices.map { $0 + base }
        }
        return all.geometry()
    }
}
