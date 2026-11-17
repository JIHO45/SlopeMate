import Foundation

/// `-SMDemo` (DEBUG 빌드만): 실제 기록과 따로 `slopemate-demo.sqlite`를 쓰고, 비어 있으면 12곳 하루씩 합성 기록을 넣는다.
/// 리프트(아래→위)를 타고 올라가 위끝 근처에서 시작하는 OSM 슬로프를 따라 내려온다. 고도는 DEM. 2D·3D·S19 확인용.
/// 이용권 잠금도 연다(DayMapView.lock). 출시 빌드에서는 항상 꺼져 있다.
nonisolated enum DemoSeed {
    static var on: Bool { DebugFailures.on("-SMDemo") }

    static func path() throws -> String {
        (try AppDatabase.defaultPath() as NSString).deletingLastPathComponent + "/slopemate-demo.sqlite"
    }

    /// 기록이 하나도 없을 때만 넣는다
    @MainActor static func seedIfEmpty(_ db: AppDatabase) {
        guard (try? db.recordings(since: .distantPast).isEmpty) == true else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let today = cal.startOfDay(for: .now)
        for (i, resort) in Resort.all.enumerated() {
            guard let map = SlopeMap.load(resortId: resort.id), let terrain = Terrain.load(resortId: resort.id),
                  let start = cal.date(byAdding: DateComponents(day: -(i + 1), hour: 10), to: today) else { continue }
            let pts = route(map: map, terrain: terrain)
            guard pts.count > 1, let rec = try? db.createRecording(resortId: resort.id, at: start) else { continue }
            let base = pts[0].alt
            for (k, p) in pts.enumerated() {
                let t = start.addingTimeInterval(Double(k) * 2)
                var point = Point(id: nil, recordingId: rec.id, t: t, lat: p.lat, lon: p.lon, hAcc: 5, gpsAlt: p.alt, vAcc: 5,
                                  speed: p.speed, baroAlt: p.alt - base, baroT: t, seq: 0)
                try? db.insert(&point)
            }
            try? db.end(rec, at: start.addingTimeInterval(Double(pts.count) * 2), reason: "user")
        }
    }

    struct P { var lat, lon, alt, speed: Double }

    /// 리프트 3개(긴 순)를 차례로: 아래→위 4m/s, 위끝 300m 안의 슬로프를 내리막 쪽으로 따라 9m/s, 끝에서 다음 리프트 아래까지 2m/s
    static func route(map: SlopeMap, terrain: Terrain) -> [P] {
        func h(_ lat: Double, _ lon: Double) -> Double {
            let r = min(max((terrain.north - lat) / terrain.step, 0), Double(terrain.rows - 1))
            let c = min(max((lon - terrain.west) / terrain.step, 0), Double(terrain.cols - 1))
            let r0 = min(Int(r), terrain.rows - 2), c0 = min(Int(c), terrain.cols - 2), a = r - Double(r0), b = c - Double(c0)
            let n = terrain.cols, z = terrain.z
            let top: Double = z[r0 * n + c0] * (1 - b) + z[r0 * n + c0 + 1] * b
            let low: Double = z[(r0 + 1) * n + c0] * (1 - b) + z[(r0 + 1) * n + c0 + 1] * b
            return top * (1 - a) + low * a
        }
        func meters(_ a: [Double], _ b: [Double]) -> Double {
            hypot((a[0] - b[0]) * 111_320, (a[1] - b[1]) * 111_320 * cos(a[0] * .pi / 180))
        }
        var out: [P] = []
        /// line을 speed로 2초 간격 점으로. straight면 고도를 양 끝 지형 높이 사이 직선으로(리프트 케이블·이동), 아니면 지형을 따른다
        func go(_ line: [[Double]], _ speed: Double, straight: Bool = false) {
            let total = zip(line, line.dropFirst()).reduce(0) { $0 + meters($1.0, $1.1) }
            let z0 = h(line[0][0], line[0][1]), z1 = h(line.last![0], line.last![1])
            var done = 0.0
            for (a, b) in zip(line, line.dropFirst()) {
                let d = meters(a, b), n = max(Int(d / (speed * 2)), 1)
                for i in 0..<n {
                    let f = Double(i) / Double(n), lat = a[0] + (b[0] - a[0]) * f, lon = a[1] + (b[1] - a[1]) * f
                    let alt = straight ? z0 + (z1 - z0) * (done + d * f) / max(total, 1) : h(lat, lon)
                    out.append(P(lat: lat, lon: lon, alt: alt, speed: speed))
                }
                done += d
            }
        }
        func stand(_ p: [Double], _ seconds: Int) {
            for _ in 0..<seconds / 2 { out.append(P(lat: p[0], lon: p[1], alt: h(p[0], p[1]), speed: 0)) }
        }
        let lifts = map.lifts.filter { $0.line.count > 1 }.sorted { meters($0.line.first!, $0.line.last!) > meters($1.line.first!, $1.line.last!) }.prefix(3)
        var here: [Double]?
        for lift in lifts {
            let bottom = lift.line.first!, top = lift.line.last!
            if let here { go([here, bottom], 2, straight: true) }
            stand(bottom, 60)
            go(lift.line, 4, straight: true)
            stand(top, 30)
            // 위끝 300m 안에 꼭짓점이 있는 슬로프 선 중 가장 많이 내려가는 것(그 점부터 낮은 끝까지). 끝이 아직 높으면 끝 100m 안의 선으로 이어 간다
            func descent(from p: [Double], within r: Double) -> [[Double]]? {
                var best: (drop: Double, line: [[Double]])?
                for s in map.slopes where s.area != true {
                    for l in s.lines where l.count > 1 {
                        guard let i = l.indices.min(by: { meters(l[$0], p) < meters(l[$1], p) }), meters(l[i], p) < r else { continue }
                        let down = h(l.last![0], l.last![1]) < h(l.first![0], l.first![1]) ? Array(l[i...]) : Array(l[...i].reversed())
                        let drop = h(p[0], p[1]) - h(down.last![0], down.last![1])
                        if down.count > 1, drop > (best?.drop ?? 30) { best = (drop, down) }
                    }
                }
                return best?.line
            }
            var run = [top]
            for _ in 0..<4 {
                guard let next = descent(from: run.last!, within: run.count == 1 ? 300 : 100) else { break }
                run += next
                if h(run.last![0], run.last![1]) - h(bottom[0], bottom[1]) < 40 { break }
            }
            if run.count == 1 { run.append(bottom) }
            go(run, 9)
            here = run.last!
        }
        if let here { stand(here, 60) }
        return out
    }
}
