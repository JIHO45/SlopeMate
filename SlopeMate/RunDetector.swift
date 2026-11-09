import Foundation

/// 하강 판정 (R3, 03-requirements 5장, 05-design 3장). 지도 없이 위치점만으로 동작한다.
/// 안드로이드도 같은 규칙과 같은 재생 파일로 같은 결과를 내야 한다(R48).
nonisolated enum RunDetector {
    /// 현장 데이터로 조정할 기준값 (06-verification 2장).
    struct Params {
        var minClimb = 20.0      // 최저점 대비 이만큼 오르면 상승(리프트)
        var minDrop = 30.0       // 상승 최고점 대비 이만큼 내려가면 하강 1회
        var maxHAcc = 50.0       // 수평 정확도가 이보다 나쁜 점은 버림
        var maxVAcc = 20.0       // GPS 고도를 쓸 때 수직 정확도 한계
        var maxSpeed = 40.0      // m/s, 직전 점 대비 이보다 빠르면 튐으로 봄
        var stopSpeed = 1.0      // m/s, 두 점 사이 속도가 이보다 느리면 정지 시간
        var baroMaxAge = 10.0    // s, 위치점과 기압 측정 시각 차이 한계
        var climbStartBand = 5.0 // m, 상승 최저점 + 이 높이 안의 마지막 점부터 "실제로 오르는 중" (R10)
        var stationRadius = 50.0 // m, 탑승장 반경 (R10)
        var maxWait = 30 * 60.0  // s, 이보다 오래 머물면 줄이 아닌 체류로 보고 버림 (R10)
    }

    struct Run: Equatable, Codable {
        var start: Date
        var end: Date
        var distance: Double     // m, 수평
        var drop: Double         // m
        var maxSpeed: Double     // m/s
        var avgSpeed: Double     // m/s, 정지 시간 제외
        var movingTime: Double   // s
        var slopeId: String? = nil // 우리 슬로프 ID(R9). 지도가 없거나 애매하면 nil
    }

    /// 상승(리프트) 구간 (05-design 3장 1·4).
    struct Ascent: Equatable, Codable {
        var start: Date          // 오르기 전 최저점
        var end: Date            // 최고점
        var rise: Double         // m
        var liftId: String? = nil
        var boardAt: Date? = nil // 탑승 시각(탑승장 반경 안 마지막 점)
        var waitSec: Double? = nil // 리프트 대기(R10). 판단이 안 되면 nil
    }

    struct Summary: Codable {
        var runs: [Run] = []
        var ascents: [Ascent] = []
        /// 기압 없이 GPS 고도로 판정한 구간이 있음 → "고도 정확도 낮음"
        var usedGPSAltitude = false
        var distance: Double { runs.reduce(0) { $0 + $1.distance } }
        var drop: Double { runs.reduce(0) { $0 + $1.drop } }
        var maxSpeed: Double { runs.map(\.maxSpeed).max() ?? 0 }

        static func + (a: Summary, b: Summary) -> Summary {
            Summary(runs: a.runs + b.runs, ascents: a.ascents + b.ascents, usedGPSAltitude: a.usedGPSAltitude || b.usedGPSAltitude)
        }
    }

    /// vehicle: 차량 이동 구간(R49). 그 안의 점은 버리고, 구간 앞뒤는 seq 재시작처럼 끊되 하강을 합치지 않는다.
    /// map: 있으면 하강마다 슬로프를 붙인다(R9). 재시작으로 나뉜 조각을 합친 뒤 한 번 맞춘다.
    static func detect(_ points: [Point], vehicle: [DateInterval] = [], map: SlopeMap? = nil, params p: Params = Params()) -> Summary {
        var summary = Summary()
        // (하강, 계열 첫 샘플에서 시작, 구간 끝까지 하강 중, 차량 구간 번호, 하강에 쓴 정제된 점)
        var pieces: [(run: Run, openStart: Bool, openEnd: Bool, part: Int, pts: [Point])] = []
        let vehicle = vehicle.sorted { $0.start < $1.start }
        let kept = clean(points, p).filter { pt in !vehicle.contains { $0.start <= pt.t && pt.t <= $0.end } }
        // 차량 구간 번호: 점보다 앞에서 끝난 차량 구간 수
        func part(_ t: Date) -> Int { vehicle.count { $0.end < t } }
        struct Key: Hashable, Comparable {
            var part: Int, seq: Int
            static func < (a: Key, b: Key) -> Bool { (a.part, a.seq) < (b.part, b.seq) }
        }
        let groups = Dictionary(grouping: kept) { Key(part: part($0.t), seq: $0.seq) }
        for key in groups.keys.sorted() {
            let pts = groups[key]!
            let series = altitudeSeries(pts, p)
            for (i, se) in series.enumerated() {
                let (found, openEnd) = descents(se.samples, p)
                // 기압 첫 값이 오기 전 몇 개 점만 GPS인 경우는 경고하지 않는다
                if se.gps && !found.isEmpty { summary.usedGPSAltitude = true }
                for (j, (a, b)) in found.enumerated() {
                    pieces.append((stats(pts, from: a, to: b, p),
                                   openStart: i == 0 && a.t == se.samples[0].t,
                                   openEnd: i == series.count - 1 && j == found.count - 1 && openEnd, part: key.part,
                                   pts: pts.filter { $0.t >= a.t && $0.t <= b.t }))
                }
                for c in climbs(se.samples, found, openEnd: openEnd) where c.hi.alt - c.lo.alt >= p.minClimb {
                    summary.ascents.append(ascent(c, se.samples, pts, map: map, p))
                }
            }
        }
        // 하강 중 재시작: 앞 seq 끝까지 이어진 하강과 다음 seq 처음부터의 하강은 1회로 합친다(R4 중복 금지).
        // 고도차는 각 seq 안에서만 계산해 더한다.
        var merged: [(run: Run, openEnd: Bool, part: Int, pts: [Point])] = []
        for pc in pieces {
            if let last = merged.last, last.openEnd, pc.openStart, last.part == pc.part {
                var r = last.run
                r.end = pc.run.end
                r.distance += pc.run.distance
                r.drop += pc.run.drop
                r.maxSpeed = max(r.maxSpeed, pc.run.maxSpeed)
                r.movingTime += pc.run.movingTime
                r.avgSpeed = r.movingTime > 0 ? r.distance / r.movingTime : 0
                merged[merged.count - 1] = (r, pc.openEnd, pc.part, last.pts + pc.pts)
            } else {
                merged.append((pc.run, pc.openEnd, pc.part, pc.pts))
            }
        }
        summary.runs = merged.map { m in
            var r = m.run
            if let map { r.slopeId = SlopeMatcher.match(m.pts, map: map) }
            return r
        }
        return summary
    }

    // MARK: 상승·리프트 대기 (R10)

    typealias Climb = (from: Date, lo: Sample, hi: Sample, open: Bool)

    /// 하강 사이 구간마다 (구간 시작, 최고점 전 최저점, 최고점, 끝에서 아직 오르는 중).
    /// 구간: 계열 시작 ~ 첫 하강 시작, 하강 끝 ~ 다음 하강 시작, 마지막 하강 끝 ~ 계열 끝(하강 중으로 끝나지 않았을 때).
    static func climbs(_ s: [Sample], _ runs: [(Sample, Sample)], openEnd: Bool) -> [Climb] {
        guard let first = s.first, let last = s.last else { return [] }
        var segs: [(Date, Date?)] = []
        var from = first.t
        for (hi, lo) in runs { segs.append((from, hi.t)); from = lo.t }
        if !openEnd { segs.append((from, nil)) }
        return segs.compactMap { a, b in
            let seg = s.filter { x in x.t >= a && (b.map { x.t <= $0 } ?? true) }
            guard let hi = seg.max(by: { $0.alt < $1.alt }),
                  let lo = seg.filter({ $0.t <= hi.t }).min(by: { $0.alt < $1.alt }) else { return nil }
            return (a, lo, hi, b == nil && hi.t == last.t)
        }
    }

    /// 리프트를 식별하고 대기를 잰다. 리프트는 실제로 오르는 점으로만 맞춰 줄에서 오래 서 있어도 흐려지지 않게 한다.
    static func ascent(_ c: Climb, _ samples: [Sample], _ pts: [Point], map: SlopeMap?, _ p: Params) -> Ascent {
        var a = Ascent(start: c.lo.t, end: c.hi.t, rise: c.hi.alt - c.lo.alt)
        guard let map else { return a }
        let climbStart = samples.last { $0.t >= c.lo.t && $0.t <= c.hi.t && $0.alt <= c.lo.alt + p.climbStartBand }?.t ?? c.lo.t
        let climb = pts.filter { $0.t >= climbStart && $0.t <= c.hi.t }
        guard let lift = SlopeMatcher.matchLift(climb, map: map) else { return a }
        a.liftId = lift.id
        // 아직 오르는 중이면 대기를 재지 않는다
        guard !c.open, let first = climb.first, let e0 = lift.line.first, let e1 = lift.line.last else { return a }
        func d(_ x: Point, _ e: [Double]) -> Double {
            distance(x, Point(recordingId: x.recordingId, t: x.t, lat: e[0], lon: e[1], hAcc: 0, gpsAlt: 0, vAcc: 0, speed: 0, seq: x.seq))
        }
        // 탑승장 = 오르기 시작한 점에 가까운 끝 (지도에는 끝점 고도가 없음)
        let station = d(first, e0) <= d(first, e1) ? e0 : e1
        let near = { (x: Point) in x.t >= c.from && d(x, station) <= p.stationRadius }
        guard let board = pts.lastIndex(where: { $0.t <= c.hi.t && near($0) }) else { return a }
        var i = board
        while i > 0, near(pts[i - 1]) { i -= 1 }
        // 수신 시작부터 탑승장에 있었으면 도착 시각을 모른다
        guard i > 0 else { return a }
        let wait = pts[board].t.timeIntervalSince(pts[i].t)
        a.boardAt = pts[board].t
        if wait <= p.maxWait { a.waitSec = wait }
        return a
    }

    // MARK: 단계

    /// 정확도가 나쁜 점, 튀는 점을 뺀다. 원본은 DB에 그대로 남는다.
    static func clean(_ points: [Point], _ p: Params) -> [Point] {
        var out: [Point] = []
        for pt in points.sorted(by: { $0.t < $1.t }) where pt.hAcc >= 0 && pt.hAcc <= p.maxHAcc {
            if let prev = out.last, prev.seq == pt.seq {
                let dt = pt.t.timeIntervalSince(prev.t)
                if dt <= 0 || distance(prev, pt) / dt > p.maxSpeed { continue }
            }
            out.append(pt)
        }
        return out
    }

    struct Sample { var t: Date; var alt: Double }
    struct Series { var gps: Bool; var samples: [Sample] }

    /// 한 seq 안에서 기압 고도와 GPS 고도는 기준이 달라 섞지 않는다.
    /// 기압 점은 모두 같은 기준이라 하나의 계열. 첫 기압 점 이전과 마지막 기압 점 이후의 GPS 점만 각각 따로 계열이 된다.
    /// 기압 점 사이에 끼인 GPS 점(기압 값이 잠깐 오래된 경우)은 고도 판정에 쓰지 않는다.
    static func altitudeSeries(_ pts: [Point], _ p: Params) -> [Series] {
        func baro(_ pt: Point) -> Double? {
            guard let alt = pt.baroAlt, let bt = pt.baroT, abs(bt.timeIntervalSince(pt.t)) <= p.baroMaxAge else { return nil }
            return alt
        }
        func gps(_ slice: ArraySlice<Point>) -> Series {
            Series(gps: true, samples: slice.filter { $0.vAcc > 0 && $0.vAcc <= p.maxVAcc }.map { Sample(t: $0.t, alt: $0.gpsAlt) })
        }
        guard let first = pts.firstIndex(where: { baro($0) != nil }),
              let last = pts.lastIndex(where: { baro($0) != nil }) else {
            return [gps(pts[...])].filter { !$0.samples.isEmpty }
        }
        let b = Series(gps: false, samples: pts[first...last].compactMap { pt in baro(pt).map { Sample(t: pt.t, alt: $0) } })
        return [gps(pts[..<first]), b, gps(pts[(last + 1)...])].filter { !$0.samples.isEmpty }
    }

    /// 히스테리시스. 하강 경계는 판정 시점이 아니라 상승 최고점 ~ 다음 상승 전 최저점으로 소급한다.
    /// 슬로프 중간에 minClimb보다 작게 오르는 곳이 있어도 하강 1회로 이어진다.
    /// openEnd: 마지막 샘플까지 하강 중이었음
    static func descents(_ s: [Sample], _ p: Params) -> (runs: [(Sample, Sample)], openEnd: Bool) {
        guard var hi = s.first else { return ([], false) }
        var lo = hi
        var descending = false
        var out: [(Sample, Sample)] = []
        for x in s.dropFirst() {
            if descending {
                if x.alt < lo.alt { lo = x }
                if x.alt - lo.alt >= p.minClimb {
                    out.append((hi, lo))
                    descending = false
                    hi = x
                }
            } else {
                if x.alt > hi.alt { hi = x }
                if hi.alt - x.alt >= p.minDrop {
                    descending = true
                    lo = x
                }
            }
        }
        if descending { out.append((hi, lo)) }
        return (out, descending)
    }

    static func stats(_ pts: [Point], from a: Sample, to b: Sample, _ p: Params) -> Run {
        let seg = pts.filter { $0.t >= a.t && $0.t <= b.t }
        var dist = 0.0, moving = 0.0, maxSpeed = 0.0
        for (x, y) in zip(seg, seg.dropFirst()) {
            let d = distance(x, y), dt = y.t.timeIntervalSince(x.t)
            dist += d
            if dt > 0, d / dt >= p.stopSpeed { moving += dt; maxSpeed = max(maxSpeed, d / dt) }
        }
        for x in seg where x.speed >= 0 && x.speed <= p.maxSpeed { maxSpeed = max(maxSpeed, x.speed) }
        return Run(start: a.t, end: b.t, distance: dist, drop: a.alt - b.alt, maxSpeed: maxSpeed, avgSpeed: moving > 0 ? dist / moving : 0, movingTime: moving)
    }

    /// 하버사인 거리(m).
    static func distance(_ a: Point, _ b: Point) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dLat = (b.lat - a.lat) * rad, dLon = (b.lon - a.lon) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * rad) * cos(b.lat * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
