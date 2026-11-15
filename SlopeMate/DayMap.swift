import Foundation
import UIKit

// 하루 기록 지도 (R50, K). 화면(DayMapView)과 공유 동영상(ShareVideo)이 같은 데이터·시간 매핑·투영·그리기를 쓴다.

/// 하루(영업일 × 리조트)의 끝난 기록 전부를 한 번에 읽은 결과.
/// 합계·하강 목록·경로를 같은 판정 결과(DayCache)에서 만들어 차량 재판정 뒤에도 서로 어긋나지 않는다.
nonisolated struct DayData {
    var day: Stats.Day
    var route: [RouteSegment]
    var clock: PlayClock

    /// recs: 그 하루의 끝난 기록. map은 캐시 열쇠에 지도 시각이 들어가므로 기록 목록과 같은 것(SlopeMap.cached)을 넘긴다.
    static func load(_ db: AppDatabase, _ day: Stats.Day, recs: [Recording], map: SlopeMap?) throws -> DayData {
        let caches = try recs.map { ($0, try db.cache($0, map: map)) }
        let fresh = Stats.days(caches.map { ($0.0, $0.1.summary) }).first { $0.id == day.id }
            ?? Stats.Day(date: day.date, resortId: day.resortId, runs: [], usedGPSAltitude: false)
        let route = caches.flatMap(\.1.route)
        return DayData(day: fresh, route: route, clock: PlayClock(route))
    }
}

/// 실제 시각 ↔ 재생 진행률(0~1). 경로가 이어지는 시간은 비율대로 재생하고(멈춘 시간 포함),
/// 기록 사이·기록 없음·차량 구간처럼 경로가 끊긴 빈 시간은 길이와 관계없이 `pause`만큼만 머문다.
nonisolated struct PlayClock {
    /// 경로가 이어지는 시간, 시각 순. 조각끼리 경계 점을 나누면 한 구간
    let spans: [DateInterval]
    /// 빈 시간 하나의 가상 길이(초): 경로 시간의 1/60 (30초 재생에서 0.5초)
    let pause: TimeInterval
    let total: TimeInterval

    init(_ route: [RouteSegment]) {
        var spans: [DateInterval] = []
        let all = route.compactMap { s in s.points.first.map { DateInterval(start: $0.t, end: s.points.last!.t) } }
        for s in all.sorted(by: { $0.start < $1.start }) {
            if let last = spans.last, s.start <= last.end {
                spans[spans.count - 1] = DateInterval(start: last.start, end: max(last.end, s.end))
            } else {
                spans.append(s)
            }
        }
        self.spans = spans
        let active = spans.reduce(0) { $0 + $1.duration }
        pause = active / 60
        total = active + pause * Double(max(0, spans.count - 1))
    }

    /// 빈 시간 안의 시각은 다음 구간 시작으로
    func progress(at t: Date) -> Double {
        guard total > 0 else { return 0 }
        var v = 0.0
        for s in spans {
            if t < s.start { break }
            if t <= s.end { return (v + t.timeIntervalSince(s.start)) / total }
            v += s.duration + pause
        }
        return min(1, v / total)
    }

    /// 빈 시간 동안에는 앞 구간 끝 시각에 머문다. 경로가 없으면 nil
    func time(at p: Double) -> Date? {
        guard let last = spans.last else { return nil }
        var v = min(max(p, 0), 1) * total
        for s in spans {
            if v <= s.duration { return s.start.addingTimeInterval(v) }
            v -= s.duration
            if v < pause { return s.end }
            v -= pause
        }
        return last.end
    }
}

nonisolated extension RouteSegment {
    /// t의 위치(앞뒤 점 사이 보간). 이 조각 시간 밖이면 nil
    func position(at t: Date) -> RoutePoint? {
        guard let a = points.first, let b = points.last, a.t <= t, t <= b.t,
              let i = points.firstIndex(where: { $0.t >= t }) else { return nil }
        guard i > 0 else { return points[0] }
        let p = points[i - 1], q = points[i]
        let f = t.timeIntervalSince(p.t) / max(q.t.timeIntervalSince(p.t), 1e-9)
        return RoutePoint(t: t, lat: p.lat + (q.lat - p.lat) * f, lon: p.lon + (q.lon - p.lon) * f)
    }

    /// t까지 지나온 부분. 끝은 t의 위치
    func prefix(upTo t: Date) -> [RoutePoint] {
        var out = points.filter { $0.t <= t }
        if let p = position(at: t), out.last?.t != t { out.append(p) }
        return out
    }
}

nonisolated extension SlopeMap {
    /// 지도로 그릴 만한 데이터: 슬로프 선 5개 이상, 리프트 1개 이상. 모자라면 S6는 목록형(공유 없음)
    var isDrawable: Bool { slopes.reduce(0) { $0 + $1.lines.count } >= 5 && !lifts.isEmpty }
}

/// 위경도 → 화면 좌표. 리조트 경계(슬로프·리프트 전부)가 rect 안에 가로세로 비율을 지켜 가운데로 들어온다.
/// 위경도 → 화면. 스키장 안내도처럼 산 위가 화면 위로 오게 돌린다:
/// 리프트 선(OSM에서 아래 → 위 방향)의 원형 중위 방위가 화면 위를 향하도록 회전한다. 리프트가 없으면 북쪽이 위.
nonisolated struct MapProjection {
    let rect: CGRect
    private let lat0: Double, lon0: Double, kx: Double
    private let cosA: Double, sinA: Double
    /// 회전한 좌표에서 그림의 가운데
    private let cu: Double, cv: Double
    /// 위도 1도당 화면 길이
    private let scale: Double

    init(_ map: SlopeMap, rect: CGRect) {
        self.rect = rect
        let all = map.slopes.flatMap { $0.lines.flatMap { $0 } } + map.lifts.flatMap(\.line)
        let lats = all.map { $0[0] }, lons = all.map { $0[1] }
        let lat0 = ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2
        let lon0 = ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2
        let kx = cos(lat0 * .pi / 180)
        self.lat0 = lat0; self.lon0 = lon0
        self.kx = kx
        let angle = Self.angle(map)
        cosA = cos(angle); sinA = sin(angle)
        let uv = all.map { c -> (Double, Double) in
            let x = (c[1] - lon0) * kx, y = c[0] - lat0
            return (x * cos(angle) - y * sin(angle), x * sin(angle) + y * cos(angle))
        }
        let us = uv.map(\.0), vs = uv.map(\.1)
        let (u0, u1, v0, v1) = (us.min() ?? 0, us.max() ?? 0, vs.min() ?? 0, vs.max() ?? 0)
        cu = (u0 + u1) / 2; cv = (v0 + v1) / 2
        scale = min(rect.width / max(u1 - u0, 1e-6), rect.height / max(v1 - v0, 1e-6))
    }

    /// 회전각(라디안). 동쪽 x·북쪽 y를 u = x cos − y sin, v = x sin + y cos(화면 오른쪽 u, 위 v)로 돌린다.
    /// 리프트 방위(북 0, 시계 +)의 원형 중위를 화면 위(+v)로. 리프트 2개 이하는 방향 벡터 합, 없으면 0.
    /// 2D·3D가 같이 쓰고, 지형 음영의 빛 방향도 이 값으로 정한다(Terrain).
    static func angle(_ map: SlopeMap) -> Double {
        let all = map.slopes.flatMap { $0.lines.flatMap { $0 } } + map.lifts.flatMap(\.line)
        let lats = all.map { $0[0] }
        let kx = cos(((lats.min() ?? 0) + (lats.max() ?? 0)) / 2 * .pi / 180)
        // 리프트마다 (동쪽, 북쪽) 벡터. 방위 = atan2(동, 북)
        let v = map.lifts.compactMap { l -> (Double, Double)? in
            guard let a = l.line.first, let b = l.line.last else { return nil }
            return ((b[1] - a[1]) * kx, b[0] - a[0])
        }
        let lx = v.reduce(0) { $0 + $1.0 }, ly = v.reduce(0) { $0 + $1.1 }
        let sum = lx == 0 && ly == 0 ? 0 : atan2(lx, ly)
        guard v.count > 2 else { return sum }
        // 원형 중위: 다른 방위들과의 각거리 합이 가장 작은 리프트 방위(옆길로 가는 몇 개에 끌리지 않게).
        // 합이 같으면(짝수 개) 벡터 합 방향에 가까운 쪽
        func dist(_ a: Double, _ b: Double) -> Double { abs(atan2(sin(a - b), cos(a - b))) }
        let bearings = v.map { atan2($0.0, $0.1) }
        let cost = bearings.map { b in bearings.reduce(0) { $0 + dist(b, $1) } }
        let best = cost.min()!
        return bearings.indices.filter { cost[$0] - best < 1e-9 }.map { bearings[$0] }.min { dist($0, sum) < dist($1, sum) }!
    }

    func point(_ lat: Double, _ lon: Double) -> CGPoint {
        let x = (lon - lon0) * kx, y = lat - lat0
        let u = x * cosA - y * sinA, v = x * sinA + y * cosA
        return CGPoint(x: rect.midX + (u - cu) * scale, y: rect.midY - (v - cv) * scale)
    }

    func coordinate(_ p: CGPoint) -> (lat: Double, lon: Double) {
        let u = (p.x - rect.midX) / scale + cu, v = (rect.midY - p.y) / scale + cv
        let x = u * cosA + v * sinA, y = -u * sinA + v * cosA
        return (y + lat0, x / kx + lon0)
    }
}

/// 지도 그리기 (07-visual-design S6 v3 시안 색). 화면은 Canvas의 CGContext, 동영상은 픽셀 버퍼에 같은 코드로 그린다.
/// 좌표계는 위가 0인 UIKit 방향.
nonisolated struct DayMapDrawing {
    var map: SlopeMap
    /// 하강 0회면 빈 배열(슬로프·리프트만)
    var route: [RouteSegment]
    var dark: Bool
    /// 지형 바탕(음영·등고선). 고도 파일이 없는 리조트는 nil: 바탕 없이 그린다
    var terrain: Terrain.Layer? = nil
    /// 슬로프·리프트 선을 그릴지. 내 경로는 늘 그린다
    var layers = MapLayers()

    struct Palette {
        var bg, lift, fill, text, dot, label, primary: UIColor
        /// 지형 바탕 (S6 지형 바탕 v1): 음영 밝은 면·그늘, 등고선(알파 0.12·0.18로 겹침)
        var hillLight, hillShadow, contour: UIColor
        init(dark: Bool) {
            func c(_ l: UInt32, _ d: UInt32) -> UIColor {
                let v = dark ? d : l
                return UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
            }
            bg = c(0xEEF6F8, 0x0F2027); lift = c(0x7C949B, 0x5A7680)
            fill = c(0x0E9AA7, 0x5CE1E6); text = c(0x087480, 0x5CE1E6); dot = c(0xFFFFFF, 0x0B161B)
            label = c(0x4A636C, 0x86A0A8); primary = c(0x111418, 0xF4F8FA)
            hillLight = c(0xF7FBFC, 0x1A323B); hillShadow = c(0xD6E5EA, 0x0A171C)
            contour = c(0x1A323B, 0xF7FBFC)
        }
    }

    /// now: 재생 시각. nil이면 경로 전체를 진하게, 있으면 지나온 부분만 진하게 + 현재 위치 점.
    /// t: 확대·이동. u: 선 굵기 배율(동영상 해상도)
    func draw(_ cg: CGContext, size: CGSize, _ proj: MapProjection, transform t: CGAffineTransform = .identity,
              now: Date?, highlight: RunDetector.Run? = nil, unit u: CGFloat = 1) {
        let c = Palette(dark: dark)
        func path(_ pts: [CGPoint]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts)
            return p
        }
        func coords(_ line: [[Double]]) -> [CGPoint] { line.map { proj.point($0[0], $0[1]).applying(t) } }
        func route(_ pts: [RoutePoint]) -> [CGPoint] { pts.map { proj.point($0.lat, $0.lon).applying(t) } }
        func stroke(_ pts: [CGPoint], _ color: UIColor, _ w: CGFloat, dash: [CGFloat] = [], alpha: CGFloat = 1) {
            guard pts.count > 1 else { return }
            cg.saveGState()
            cg.addPath(path(pts))
            cg.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
            cg.setLineWidth(w * u)
            cg.setLineCap(dash.isEmpty ? .round : .butt)
            cg.setLineJoin(.round)
            cg.setLineDash(phase: 0, lengths: dash.map { $0 * u })
            cg.strokePath()
            cg.restoreGState()
        }

        cg.setFillColor(c.bg.cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        if let terrain {
            cg.saveGState()
            cg.concatenate(terrain.imageTransform(proj, t))
            cg.interpolationQuality = .high
            cg.draw(terrain.image, in: CGRect(x: 0, y: 0, width: terrain.terrain.cols, height: terrain.terrain.rows))
            cg.restoreGState()
            // 등고선: 격자 좌표 경로를 그대로 두고 변환만 바꾼다. 선 굵기는 확대해도 그대로. 음영처럼 바깥 10%에서 사라진다
            let g = terrain.gridTransform(proj, t), k = sqrt(abs(g.a * g.d - g.b * g.c))
            cg.saveGState()
            if let mask = terrain.mask {
                let m = terrain.imageTransform(proj, t)
                cg.concatenate(m)
                cg.clip(to: CGRect(x: 0, y: 0, width: terrain.terrain.cols, height: terrain.terrain.rows), mask: mask)
                cg.concatenate(m.inverted())
            }
            for (line, w, a) in [(terrain.minor, 0.5, 0.12), (terrain.major, 1.0, 0.18)] {
                cg.saveGState()
                cg.concatenate(g)
                cg.addPath(line)
                cg.setStrokeColor(c.contour.withAlphaComponent(a).cgColor)
                cg.setLineWidth(w * u / k)
                cg.setLineCap(.butt)
                cg.strokePath()
                cg.restoreGState()
            }
            cg.restoreGState()
        }
        // 슬로프: 난이도 색 2.5pt (S6 지도 난이도 색 v1). 지형 바탕이 있든 없든 같은 색
        if layers.slopes {
            for s in map.slopes {
                let color = SlopeStyle.color(difficulty: s.difficulty, dark: dark)
                let casing = SlopeStyle.casing(SlopeStyle.level(s.difficulty), dark: dark).map { v in
                    UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
                }
                for line in s.lines {
                    let pts = coords(line)
                    if s.area == true, pts.count > 2 {
                        cg.addPath(path(pts))
                        cg.setFillColor(color.withAlphaComponent(0.2).cgColor)
                        cg.fillPath()
                    }
                    if let casing { stroke(pts, casing, 3.5) }
                    stroke(pts, color, 2.5)
                }
            }
        }
        if layers.lifts { for l in map.lifts { stroke(coords(l.line), c.lift, 1.5, dash: [4, 4]) } }

        // 하강은 강조색 실선, 리프트는 점선, 그 밖(걷기·평지)은 옅은 가는 선
        func style(_ k: RouteSegment.Kind) -> (UIColor, CGFloat, [CGFloat], CGFloat) {
            switch k {
            case .run: (c.fill, 5, [], 1)
            case .lift: (c.text, 2.5, [5, 4], 1)
            case .other: (c.fill, 2, [], 0.5)
            }
        }
        for seg in self.route {
            let (color, w, dash, a) = style(seg.kind)
            if let now {
                stroke(route(seg.points), color, w, dash: dash, alpha: a * 0.3)
                stroke(route(seg.prefix(upTo: now)), color, w, dash: dash, alpha: a)
            } else {
                stroke(route(seg.points), color, w, dash: dash, alpha: a)
            }
        }
        if let h = highlight {
            for seg in self.route where seg.kind == .run {
                stroke(route(seg.points.filter { $0.t >= h.start && $0.t <= h.end }), c.text, 7)
            }
        }
        if let now, let p = position(at: now) {
            let q = proj.point(p.lat, p.lon).applying(t)
            cg.setFillColor(c.fill.withAlphaComponent(dark ? 0.25 : 0.2).cgColor)
            cg.fillEllipse(in: CGRect(x: q.x - 16 * u, y: q.y - 16 * u, width: 32 * u, height: 32 * u))
            let dot = CGRect(x: q.x - 8 * u, y: q.y - 8 * u, width: 16 * u, height: 16 * u)
            cg.setFillColor(c.dot.cgColor)
            cg.fillEllipse(in: dot)
            cg.setStrokeColor(c.text.cgColor)
            cg.setLineWidth(3 * u)
            cg.strokeEllipse(in: dot)
        }
    }

    /// 재생 시각의 위치 (지도 따라가기용)
    func position(at now: Date) -> RoutePoint? { route.lazy.compactMap { $0.position(at: now) }.first }
}
