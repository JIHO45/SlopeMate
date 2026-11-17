import UIKit

/// 지도 표시 설정. DayMapView가 @AppStorage("mapShowSlopes")·("mapShowLifts")(2D, 기본 켬)·("mapShowSlopes3D")·("mapShowLifts3D")(3D, 기본 끔)로 기억한다
nonisolated struct MapLayers: Equatable, Sendable {
    var slopes = true
    var lifts = true
    /// 공유 동영상: 슬로프·리프트 선 없음
    static let none = MapLayers(slopes: false, lifts: false)

    /// 3D 난이도 선·리프트(mapShowSlopes3D·mapShowLifts3D) 첫 값: 예전에 직접 고른 2D 값이 있으면 한 번만 이어받는다. 그 뒤로는 2D·3D 따로
    static func migrate3D(_ d: UserDefaults = .standard) {
        for k in ["mapShowSlopes", "mapShowLifts"] {
            guard !d.bool(forKey: k + "3DMigrated") else { continue }
            d.set(true, forKey: k + "3DMigrated")
            if d.object(forKey: k + "3D") == nil, let v = d.object(forKey: k) as? Bool { d.set(v, forKey: k + "3D") }
        }
    }
}

/// 슬로프 난이도 단계와 색 (07-visual-design "S6 지도 난이도 색 v1")
nonisolated enum SlopeStyle {
    enum Level: CaseIterable, Sendable { case beginner, intermediate, advanced, expert, unknown }

    /// OSM piste:difficulty → 단계. novice·easy / intermediate / advanced / expert·freeride·extreme / 그 밖·nil
    static func level(_ difficulty: String?) -> Level {
        switch difficulty?.lowercased() {
        case "novice", "easy": .beginner
        case "intermediate": .intermediate
        case "advanced": .advanced
        case "expert", "freeride", "extreme": .expert
        default: .unknown
        }
    }

    /// sRGB hex. 3D 눈 띠 위 선은 dark: false로 부른다
    static func hex(_ level: Level, dark: Bool) -> UInt32 {
        switch level {
        case .beginner: dark ? 0x4CC46F : 0x2E9E4F
        case .intermediate: dark ? 0x7C8FF0 : 0x3A4FB8
        case .advanced: dark ? 0xFF6B6B : 0xD93A3A
        case .expert: 0x111418
        case .unknown: 0x7C8A90
        }
    }

    static func color(difficulty: String?, dark: Bool) -> UIColor {
        let v = hex(level(difficulty), dark: dark)
        return UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// 2D 어둡게의 최상급만 0x8A979D(선 아래 양쪽 0.5pt), 나머지는 nil
    static func casing(_ level: Level, dark: Bool) -> UInt32? {
        dark && level == .expert ? 0x8A979D : nil
    }

    /// "초급"·"중급"·"상급"·"최상급". unknown은 nil(범례에서는 "정보 없음")
    static func label(_ level: Level) -> String? {
        switch level {
        case .beginner: "초급"
        case .intermediate: "중급"
        case .advanced: "상급"
        case .expert: "최상급"
        case .unknown: nil
        }
    }
}

/// 지도에서 누른 슬로프 찾기. 2D·3D가 투영만 다르게 넘긴다
nonisolated enum SlopePick {
    struct Hit: Equatable, Sendable {
        let slopeId: String
        let name: String?           // OSM 이름. nil이면 "이름 정보 없음"
        let difficulty: String?
        let anchor: CGPoint         // 선 위에서 누른 점과 가장 가까운 점(화면 좌표). 말풍선 자리
        var area = false            // 면 슬로프. 이름이 없으면 "슬로프 구역"
    }

    /// 허용 거리(pt)
    static let tolerance: CGFloat = 22

    /// project: [위도, 경도] → 화면 좌표. 보이지 않으면 nil(그 점에 걸친 선분은 건너뜀)
    /// 면 슬로프는 안쪽을 누르면 허용 거리와 상관없이 맞음(anchor는 누른 점). 겹치면 테두리가 가까운 쪽
    static func nearest(to point: CGPoint, in map: SlopeMap, tolerance: CGFloat = tolerance,
                        project: ([Double]) -> CGPoint?) -> Hit? {
        var best: (d: CGFloat, hit: Hit)?
        for slope in map.slopes {
            var dist = CGFloat.infinity, anchor = point, inside = false
            for line in slope.lines {
                let pts = line.map(project)
                // 고리 일부가 안 보이면(투영 nil) 짝홀이 틀어지니 안쪽 판정을 하지 않는다
                let ring = slope.area == true && !pts.contains { $0 == nil }
                for (a, b) in zip(pts, pts.dropFirst()) {
                    guard let a, let b else { continue }
                    let q = closest(point, a, b), d = hypot(q.x - point.x, q.y - point.y)
                    if d < dist { dist = d; anchor = q }
                    // 짝홀 규칙: 누른 점에서 오른쪽으로 그은 반직선이 선분과 만나는 횟수
                    if ring, (a.y > point.y) != (b.y > point.y),
                       point.x < a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x) { inside.toggle() }
                }
            }
            if inside { anchor = point } else if dist > tolerance { continue }
            if best == nil || dist < best!.d {
                best = (dist, Hit(slopeId: slope.id, name: slope.name, difficulty: slope.difficulty, anchor: anchor, area: slope.area == true))
            }
        }
        return best?.hit
    }

    private static func closest(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
        guard len2 > 0 else { return a }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return CGPoint(x: a.x + t * dx, y: a.y + t * dy)
    }
}
