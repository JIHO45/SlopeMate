import Foundation

/// 하강 1회를 내장 지도의 슬로프에 맞춘다. 지도와 위치점만 쓰는 순수 계산.
nonisolated enum SlopeMatcher {
    /// 현장 데이터로 조정할 기준값.
    struct Params {
        var maxDistance = 30.0   // m, 이 거리 안의 점만 그 슬로프에 속한다고 봄
        var minShare = 0.6       // 하강 점 중 이 비율 이상이 한 슬로프에 있어야 이름을 붙임
        var minLead = 0.15       // 1등과 2등 비율 차이가 이보다 작으면 애매 → nil
    }

    /// 비교 대상 선: 슬로프 또는 리프트.
    struct Target { var id: String; var lines: [[[Double]]]; var area = false }

    /// 하강 1회의 정제된 위치점으로 우리 슬로프 ID를 찾는다. 애매하면 nil("알 수 없는 슬로프").
    static func match(_ points: [Point], map: SlopeMap, params p: Params = Params()) -> String? {
        match(points, map.slopes.map { Target(id: $0.id, lines: $0.lines, area: $0.area == true) }, params: p)
    }

    /// 상승 구간의 점으로 리프트를 찾는다(R10). 규칙은 슬로프와 같다.
    static func matchLift(_ points: [Point], map: SlopeMap, params p: Params = Params()) -> SlopeMap.Lift? {
        let id = match(points, map.lifts.map { Target(id: $0.id, lines: [$0.line]) }, params: p)
        return map.lifts.first { $0.id == id }
    }

    // ponytail: 점 × 선분 전수 비교. 지도가 작아(선분 ~2000) 충분, 느려지면 격자 색인
    static func match(_ points: [Point], _ targets: [Target], params p: Params = Params()) -> String? {
        guard !points.isEmpty, !targets.isEmpty else { return nil }
        let shares = targets.map { t in
            let hits = points.filter { distance(from: $0, to: t) <= p.maxDistance }.count
            return (id: t.id, share: Double(hits) / Double(points.count))
        }.sorted { $0.share > $1.share }
        let top = shares[0]
        let second = shares.count > 1 ? shares[1].share : 0
        guard top.share >= p.minShare, top.share - second >= p.minLead else { return nil }
        return top.id
    }

    /// 점에서 대상까지 거리(m). 면 슬로프는 안에 있으면 0.
    static func distance(from point: Point, to target: Target) -> Double {
        // 점 주변 평면 근사: x = 경도·cos(위도)·111320, y = 위도·110540
        let kx = cos(point.lat * .pi / 180) * 111_320, ky = 110_540.0
        let px = point.lon * kx, py = point.lat * ky
        var best = Double.infinity
        for line in target.lines {
            let xy = line.map { ($0[1] * kx, $0[0] * ky) }
            if target.area, inside(px, py, xy) { return 0 }
            for (a, b) in zip(xy, xy.dropFirst()) {
                best = min(best, segmentDistance(px, py, a, b))
            }
        }
        return best
    }

    /// 선분 a–b까지 거리.
    private static func segmentDistance(_ px: Double, _ py: Double, _ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let dx = b.0 - a.0, dy = b.1 - a.1
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((px - a.0) * dx + (py - a.1) * dy) / len2))
        return hypot(px - (a.0 + t * dx), py - (a.1 + t * dy))
    }

    /// 닫힌 고리 안인지 (반직선 교차 횟수).
    private static func inside(_ px: Double, _ py: Double, _ ring: [(Double, Double)]) -> Bool {
        var result = false
        var j = ring.count - 1
        for i in ring.indices {
            let (xi, yi) = ring[i], (xj, yj) = ring[j]
            if (yi > py) != (yj > py), px < (xj - xi) * (py - yi) / (yj - yi) + xi {
                result.toggle()
            }
            j = i
        }
        return result
    }
}
