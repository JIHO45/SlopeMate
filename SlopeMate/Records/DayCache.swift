import Foundation
import GRDB

/// 끝난 기록의 판정 결과와 줄인 경로 (R50, K). 하루·시즌 화면이 매번 판정하지 않고 바로 그리게 한다.
/// 판정 기준 버전·차량 구간 조회 시각·지도 데이터 시각 중 하나라도 바뀌면 다시 계산한다.
nonisolated struct DayCache: Codable {
    var summary: RunDetector.Summary
    var route: [RouteSegment]
}

nonisolated struct RouteSegment: Codable, Equatable {
    enum Kind: String, Codable { case run, lift, other }
    var kind: Kind
    var points: [RoutePoint]
}

nonisolated struct RoutePoint: Codable, Equatable {
    var t: Date
    var lat: Double
    var lon: Double
}

nonisolated enum Route {
    /// m. 시간 동기 거리 기준이라 재생 위치도 이 오차 안에서 맞는다
    static let tolerance = 3.0

    /// 조각: seq가 바뀌거나 사이에 차량 구간이 있으면 끊는다("기록 없음"은 선을 잇지 않음).
    /// 조각 안에서 하강·상승·그 밖으로 나누고, 경계 점은 양쪽에 넣어 선이 이어지게 한다.
    static func build(_ points: [Point], summary: RunDetector.Summary, vehicle: [DateInterval]) -> [RouteSegment] {
        let kept = RunDetector.clean(points, .init()).filter { pt in !vehicle.contains { $0.start <= pt.t && pt.t <= $0.end } }
        func kind(_ t: Date) -> RouteSegment.Kind {
            if summary.runs.contains(where: { $0.start <= t && t <= $0.end }) { return .run }
            if summary.ascents.contains(where: { $0.start <= t && t <= $0.end }) { return .lift }
            return .other
        }
        var out: [RouteSegment] = []
        var cur: RouteSegment?
        var prev: Point?
        func flush() {
            if let c = cur, c.points.count > 1 { out.append(RouteSegment(kind: c.kind, points: simplify(c.points, tolerance))) }
            cur = nil
        }
        for pt in kept {
            let rp = RoutePoint(t: pt.t, lat: pt.lat, lon: pt.lon), k = kind(pt.t)
            if let p = prev, p.seq != pt.seq || vehicle.contains(where: { $0.end > p.t && $0.start < pt.t }) { flush() }
            if let c = cur, c.kind != k {
                flush()
                cur = RouteSegment(kind: k, points: [c.points.last!])
            }
            cur = cur ?? RouteSegment(kind: k, points: [])
            cur!.points.append(rp)
            prev = pt
        }
        flush()
        return out
    }

    /// 시간 동기 거리(점과, 양 끝을 그 점의 시각으로 보간한 위치 사이 거리)를 쓰는 RDP.
    /// 직선 위에서 멈춘 시간도 시작·끝 점이 남는다.
    static func simplify(_ p: [RoutePoint], _ tol: Double) -> [RoutePoint] {
        guard p.count > 2 else { return p }
        var keep = [Bool](repeating: false, count: p.count)
        keep[0] = true; keep[p.count - 1] = true
        var stack = [(0, p.count - 1)]
        while let (a, b) = stack.popLast() {
            var best = 0.0, idx = -1
            for i in (a + 1)..<b {
                let d = sed(p[i], p[a], p[b])
                if d > best { best = d; idx = i }
            }
            if idx >= 0, best > tol { keep[idx] = true; stack += [(a, idx), (idx, b)] }
        }
        return p.indices.filter { keep[$0] }.map { p[$0] }
    }

    static func sed(_ x: RoutePoint, _ a: RoutePoint, _ b: RoutePoint) -> Double {
        let span = b.t.timeIntervalSince(a.t)
        let f = span > 0 ? x.t.timeIntervalSince(a.t) / span : 0
        let lat = a.lat + (b.lat - a.lat) * f, lon = a.lon + (b.lon - a.lon) * f
        let kx = cos(x.lat * .pi / 180) * 111_320, ky = 110_540.0
        return hypot((x.lon - lon) * kx, (x.lat - lat) * ky)
    }
}

nonisolated extension AppDatabase {
    static func osmStamp(_ map: SlopeMap?) -> String { map?.osmTimestamp ?? "" }

    /// 다시 계산해 저장한다. 리프트 대기 표본도 같은 트랜잭션에서 맞춘다.
    /// 계산하는 동안 차량 구간이 바뀌었으면 쓰지 않는다(바꾼 쪽이 다시 계산함).
    @discardableResult
    func refreshCache(_ rec: Recording, map: SlopeMap?) throws -> DayCache {
        let f = try file(rec)
        let vehicle = f.vehicle.map(\.interval)
        let summary = RunDetector.detect(f.points, vehicle: vehicle, map: map)
        let cache = DayCache(summary: summary, route: Route.build(f.points, summary: summary, vehicle: vehicle))
        let data = try RecordingFile.encoder.encode(cache)
        try queue.write { db in
            let now = try Recording.fetchOne(db, key: rec.id)
            guard let now, now.endedAt != nil, now.vehicleQueriedAt == f.recording.vehicleQueriedAt else { return }
            try db.execute(sql: """
                INSERT OR REPLACE INTO recording_cache (recordingId, version, vehicleQueriedAt, osmTimestamp, data)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [rec.id, RunDetector.rulesVersion, now.vehicleQueriedAt, Self.osmStamp(map), data])
            try Self.syncLiftWaits(db, now, summary)
        }
        return cache
    }

    /// 저장된 결과. 없거나 낡았으면 다시 계산한다. 끝난 기록만.
    func cache(_ rec: Recording, map: SlopeMap?) throws -> DayCache {
        if let c = try stored(rec, map: map) { return c }
        return try refreshCache(rec, map: map)
    }

    /// 저장된 결과가 있고 낡지 않았을 때만. 없으면 nil(다시 계산하지 않는다) — 메인 스레드에서 읽을 때 쓴다
    func stored(_ rec: Recording, map: SlopeMap?) throws -> DayCache? {
        let data = try queue.read { db in
            try Data.fetchOne(db, sql: """
                SELECT c.data FROM recording_cache c JOIN recording r ON r.id = c.recordingId
                WHERE c.recordingId = ? AND c.version = ? AND c.vehicleQueriedAt IS r.vehicleQueriedAt AND c.osmTimestamp = ?
                """, arguments: [rec.id, RunDetector.rulesVersion, Self.osmStamp(map)])
        }
        return data.flatMap { try? RecordingFile.decoder.decode(DayCache.self, from: $0) }
    }

    /// 결과가 없거나 낡은 끝난 기록 (종료 직후 앱이 죽은 경우, 차량 구간 재조회, 기준·지도 변경)
    func recordingsNeedingCache(osmStamp: (String) -> String) throws -> [Recording] {
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT r.*, c.osmTimestamp AS cacheOsm,
                  (c.recordingId IS NULL OR c.version != ? OR c.vehicleQueriedAt IS NOT r.vehicleQueriedAt) AS stale
                FROM recording r LEFT JOIN recording_cache c ON c.recordingId = r.id
                WHERE r.endedAt IS NOT NULL
                """, arguments: [RunDetector.rulesVersion])
        }
        return try rows.compactMap { row in
            let rec = try Recording(row: row)
            let stale: Bool = row["stale"]
            return stale || (row["cacheOsm"] as String?) != osmStamp(rec.resortId) ? rec : nil
        }
    }
}
