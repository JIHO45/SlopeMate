import Foundation

/// S19 하강 상세 계산 (R52, L). 숫자 4칸은 RunDetector.Run을 그대로 쓰고, 여기서는 그래프·재생·시즌 비교만 만든다.
nonisolated enum RunDetail {
    /// 하강 하나의 재생 길이(초)
    static let playSeconds = 20.0
    /// 3D 진입: 날아 들어온 뒤 하강 전체를 보여 주는 시간(초), 그다음 자동 재생. 재생이 끝나면 머무는 시간 뒤 전체 보기로(첫 시험값)
    static let entryHold = 1.5, endHold = 1.0

    /// 속도 m/s 또는 고도 m
    struct Value: Equatable, Sendable { var t: Date; var v: Double }
    /// 끊기지 않은 한 조각. altitude는 비어 있을 수 있다
    struct Piece: Equatable, Sendable { var speed: [Value]; var altitude: [Value] }

    struct Series: Equatable, Sendable {
        var start: Date, end: Date            // run 안에서 앞뒤 정지를 뺀 구간(재생도 이 구간)
        var pieces: [Piece]
        var gaps: [DateInterval]              // 조각 사이 "기록 없음"
        var maxAt: Date?                      // 최고 속도 시각
        var stopped: TimeInterval             // 멈춘 시간(초)
        var lowAccuracy: Bool                 // GPS 고도 사용
        var altitudeRange: ClosedRange<Double>?

        /// 그래프 가로 위치 0…1 (실제 시각 비례)
        func x(_ t: Date) -> Double {
            let span = end.timeIntervalSince(start)
            return span > 0 ? min(max(t.timeIntervalSince(start) / span, 0), 1) : 0
        }
        func speed(at t: Date) -> Double? { RunDetail.value(pieces.map(\.speed), at: t) }
        func altitude(at t: Date) -> Double? { RunDetail.value(pieces.map(\.altitude), at: t) }
    }

    /// 시각이 든 조각에서 앞뒤 표본 보간. 끊긴 구간·범위 밖은 nil
    static func value(_ lines: [[Value]], at t: Date) -> Double? {
        for line in lines {
            guard let first = line.first, let last = line.last, first.t <= t, t <= last.t else { continue }
            guard let i = line.firstIndex(where: { $0.t >= t }) else { return last.v }
            if i == 0 || line[i].t == t { return line[i].v }
            let a = line[i - 1], b = line[i]
            return a.v + (b.v - a.v) * t.timeIntervalSince(a.t) / b.t.timeIntervalSince(a.t)
        }
        return nil
    }

    /// 앞뒤 정지를 자르는 기준: 앞뒤 trimWindow초 사이 고도가 trimRate(m/s) 넘게 내려가면 움직임.
    /// 10초에 3m: 기압 떨림(±1m)·바닥 평지에서 천천히 밀려 내려가기(0.1m/s 안팎)보다 크고, 완경사 활주보다 작다
    static let trimWindow = 5.0, trimRate = 0.3

    /// points: 그 하루 끝난 기록들의 원본 점 전부(기록 ID가 섞여 있어도 됨). vehicle: 차량 구간. trim: 앞뒤 정지 빼기(테스트만 끈다)
    static func series(_ points: [Point], run: RunDetector.Run, vehicle: [DateInterval],
                       params p: RunDetector.Params = .init(), trim: Bool = true) -> Series {
        let vehicle = vehicle.sorted { $0.start < $1.start }
        let byRec = Dictionary(grouping: points, by: \.recordingId)
        // 기압 상대고도 → 해발: (기록, seq)마다 GPS 고도 − 기압 고도의 중앙값 (하강 밖 점 포함)
        struct Key: Hashable { var rec: UUID, seq: Int }
        var offset: [Key: Double] = [:]
        for (key, pts) in Dictionary(grouping: points, by: { Key(rec: $0.recordingId, seq: $0.seq) }) {
            let baro = pts.filter { pt in
                pt.baroAlt != nil && pt.baroT.map { abs($0.timeIntervalSince(pt.t)) <= p.baroMaxAge } == true
            }
            let good = baro.filter { $0.vAcc > 0 && $0.vAcc <= p.maxVAcc }
            offset[key] = median((good.isEmpty ? baro : good).map { $0.gpsAlt - $0.baroAlt! })
        }
        // 조각: 기록·seq·차량 구간 번호가 같은 점 (RunDetector.detect·Route.build와 같은 끊기)
        struct Group: Hashable { var rec: UUID, seq: Int, part: Int }
        let kept = byRec.values.flatMap { RunDetector.clean($0, p) }
            .filter { pt in !vehicle.contains { $0.start <= pt.t && pt.t <= $0.end } }
        let groups = Dictionary(grouping: kept) { pt in
            Group(rec: pt.recordingId, seq: pt.seq, part: vehicle.count { $0.end < pt.t })
        }
        var pieces: [Piece] = []
        var stopped = 0.0, low = false
        for (g, all) in groups {
            let pts = all.sorted { $0.t < $1.t }
            let seg = pts.filter { $0.t >= run.start && $0.t <= run.end }
            guard seg.count > 1 else { continue }
            // 속도: RunDetector.stats의 최고 속도와 같은 규칙(이웃 점 속도는 stopSpeed 이상만, 측정 속도는 0...maxSpeed만)
            var speed: [Value] = []
            for (i, x) in seg.enumerated() {
                var v = x.speed >= 0 && x.speed <= p.maxSpeed ? x.speed : 0
                if i > 0 {
                    let d = RunDetector.distance(seg[i - 1], x), dt = x.t.timeIntervalSince(seg[i - 1].t)
                    if dt > 0 {
                        if d / dt >= p.stopSpeed { v = max(v, d / dt) } else { stopped += dt }
                    }
                }
                speed.append(Value(t: x.t, v: v))
            }
            // 고도: 그 묶음 전체로 계열을 나눈 뒤 하강 구간만
            let off = offset[Key(rec: g.rec, seq: g.seq)] ?? 0
            var altitude: [Value] = []
            for se in RunDetector.altitudeSeries(pts, p) {
                let inRun = se.samples.filter { $0.t >= run.start && $0.t <= run.end }
                if se.gps && !inRun.isEmpty { low = true }
                altitude += inRun.map { Value(t: $0.t, v: se.gps ? $0.alt : $0.alt + off) }
            }
            pieces.append(Piece(speed: speed, altitude: altitude.sorted { $0.t < $1.t }))
        }
        pieces.sort { $0.speed[0].t < $1.speed[0].t }
        // 앞뒤 정지(위에서 기다림 등): 하강은 고도 최고점~최저점이라 고도가 평평한 채 서 있던 시간이 들어간다. 그래프·재생에서만 뺀다(멈춘 시간은 그대로)
        // 속도는 서 있어도 GPS 떨림에 튀어 고도로 자른다: 앞뒤 trimWindow초(조각 안) 고도가 trimRate 넘게 내려가는 점이 움직임. 첫 움직임 ~ 마지막 움직임
        // ponytail: GPS 고도만(정확도 낮음)이면 떨림이 커 덜 잘릴 수 있다
        var from = run.start, to = run.end
        var moving: [Date] = []
        for a in pieces.map(\.altitude) {
            guard let f = a.first?.t, let l = a.last?.t else { continue }
            for x in a {
                let t0 = max(x.t - trimWindow, f), t1 = min(x.t + trimWindow, l)
                if t1 > t0, let hi = value([a], at: t0), let lo = value([a], at: t1),
                   (hi - lo) / t1.timeIntervalSince(t0) >= trimRate { moving.append(x.t) }
            }
        }
        if trim, let m0 = moving.first, let m1 = moving.last, m0 < m1 {
            (from, to) = (m0, m1)
            pieces = pieces.compactMap { pc in
                let sp = pc.speed.filter { from <= $0.t && $0.t <= to }
                return sp.count > 1 ? Piece(speed: sp, altitude: pc.altitude.filter { from <= $0.t && $0.t <= to }) : nil
            }
        }
        let gaps = zip(pieces, pieces.dropFirst()).map { DateInterval(start: $0.speed.last!.t, end: $1.speed[0].t) }
        let speeds = pieces.flatMap(\.speed)
        let maxAt = speeds.indices.max { speeds[$0].v < speeds[$1].v || (speeds[$0].v == speeds[$1].v && $0 > $1) }.map { speeds[$0].t }
        let alts = pieces.flatMap(\.altitude).map(\.v)
        let range = alts.min().flatMap { lo in alts.max().map { lo...$0 } }
        return Series(start: from, end: to, pieces: pieces, gaps: gaps, maxAt: maxAt,
                      stopped: stopped, lowAccuracy: low, altitudeRange: range)
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// 3D·2D에 넘길 이 하강만의 경로. 양 끝은 run.start·end 시각으로 보간한 점(그래프 구간과 같은 자리). PlayClock(이 결과)로 재생한다
    static func route(_ route: [RouteSegment], run: RunDetector.Run) -> [RouteSegment] {
        route.filter { $0.kind == .run }.compactMap { seg in
            var pts = seg.points.filter { $0.t > run.start && $0.t < run.end }
            if let p = at(seg.points, run.start) { pts.insert(p, at: 0) }
            if let p = at(seg.points, run.end), p.t > run.start { pts.append(p) }
            return pts.count > 1 ? RouteSegment(kind: .run, points: pts) : nil
        }
    }

    /// 조각 안 t 시각의 보간 점. 범위 밖은 nil
    static func at(_ pts: [RoutePoint], _ t: Date) -> RoutePoint? {
        guard let first = pts.first, let last = pts.last, first.t <= t, t <= last.t,
              let i = pts.firstIndex(where: { $0.t >= t }) else { return nil }
        if i == 0 || pts[i].t == t { return pts[i] }
        let a = pts[i - 1], b = pts[i], f = t.timeIntervalSince(a.t) / b.t.timeIntervalSince(a.t)
        return RoutePoint(t: t, lat: a.lat + (b.lat - a.lat) * f, lon: a.lon + (b.lon - a.lon) * f)
    }

    struct History: Equatable, Sendable {
        var maxSpeeds: [Double]               // m/s, 이번 시즌 이 슬로프 전체, 시작 시각 순
        var avgSpeeds: [Double]
        var count: Int { maxSpeeds.count }
        var bestIndex: Int                    // 시즌 최고가 나온 순번(0부터)
        var index: Int                        // 보고 있는 하강의 순번(0부터)
    }

    /// 같은 시즌·리조트·슬로프의 하강 전부. seasonDays: 그 시즌의 하루 기록들. namesShown: SlopeNames.isShown(resortId)
    static func history(seasonDays: [Stats.Day], resortId: String, run: RunDetector.Run, namesShown: Bool) -> History? {
        guard namesShown, let slope = run.slopeId, let season = Stats.season(of: BusinessDay.start(of: run.start)) else { return nil }
        let runs = seasonDays.filter { $0.resortId == resortId && Stats.season(of: $0.date) == season }
            .flatMap(\.runs).filter { $0.slopeId == slope }.sorted { $0.start < $1.start }
        guard let index = runs.firstIndex(where: { $0.start == run.start }) else { return nil }
        let maxes = runs.map(\.maxSpeed)
        let best = maxes.indices.max { maxes[$0] < maxes[$1] || (maxes[$0] == maxes[$1] && $0 > $1) } ?? 0
        return History(maxSpeeds: maxes, avgSpeeds: runs.map(\.avgSpeed), bestIndex: best, index: index)
    }

    /// "기록 없음 10:38~10:39 외 1". 없으면 nil
    static func gapText(_ gaps: [DateInterval]) -> String? {
        guard let g = gaps.first else { return nil }
        let a = hm(g.start), b = hm(g.end)
        return "기록 없음 " + (a == b ? a : "\(a)~\(b)") + (gaps.count > 1 ? " 외 \(gaps.count - 1)" : "")
    }

    static func hm(_ d: Date) -> String {
        let c = HomeData.seoul.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 속도 눈금 3줄(km/h): 0과 30의 배수(최고가 30 미만이면 10의 배수). 맨 위 줄은 최고를 넘지 않게
    static func speedTicks(max kmh: Double) -> [Double] {
        let unit = kmh < 30 ? 10.0 : 30.0
        let step = max(unit, (kmh / 2 / unit).rounded(.down) * unit)
        return [0, step, step * 2]
    }

    struct Loaded: Sendable { var series: Series; var history: History? }

    /// 메인 스레드 밖에서 부른다. day.runs[index]가 대상
    static func load(_ db: AppDatabase, day: Stats.Day, index: Int) throws -> Loaded {
        let run = day.runs[index]
        let files = try db.recordings(of: day).map { try db.file($0) }
        let s = series(files.flatMap(\.points), run: run, vehicle: files.flatMap { $0.vehicle.map(\.interval) })
        let shown = SlopeNames.isShown(day.resortId)
        guard shown, run.slopeId != nil, let season = Stats.season(of: day.date) else { return Loaded(series: s, history: nil) }
        let days = Stats.days(try HomeData.days(db, since: HomeData.seasonStart(season)), inSeason: season)
        return Loaded(series: s, history: history(seasonDays: days, resortId: day.resortId, run: run, namesShown: shown))
    }
}
