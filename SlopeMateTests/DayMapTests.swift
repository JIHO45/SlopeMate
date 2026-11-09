import AVFoundation
import Foundation
import Testing
@testable import SlopeMate

@Suite(.serialized) struct DayMapTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func seg(_ kind: RouteSegment.Kind, _ from: TimeInterval, _ to: TimeInterval) -> RouteSegment {
        RouteSegment(kind: kind, points: [RoutePoint(t: t0 + from, lat: 37.2, lon: 128.8), RoutePoint(t: t0 + to, lat: 37.21, lon: 128.8)])
    }

    /// 두 기록(사이 2시간 빈 시간) + 첫 기록 안의 "기록 없음": 빈 시간은 pause만큼만, 경로 시간(정지 포함)은 비율대로
    @Test func playClock() {
        // 기록 1: 0~600 리프트, 600~900 하강(경계 점 공유 → 한 구간), 끊김 뒤 1200~1500
        // 기록 2: 8700~9300
        let c = PlayClock([seg(.lift, 0, 600), seg(.run, 600, 900), seg(.run, 1200, 1500), seg(.other, 8700, 9300)])
        #expect(c.spans.count == 3)
        let active = 900.0 + 300 + 600
        #expect(c.pause == active / 60)
        #expect(abs(c.total - (active + 2 * c.pause)) < 1e-9)
        // 구간 안: 비율 유지(정지·느린 이동도 실제 시간 비율 그대로)
        #expect(abs(c.progress(at: t0 + 450) - 450 / c.total) < 1e-9)
        #expect(abs(c.progress(at: t0 + 900) - 900 / c.total) < 1e-9)
        // 경계 양쪽: 끝 직전과 다음 구간 시작 사이는 pause만큼만 벌어진다(빈 시간 300초·2시간과 관계없음)
        #expect(abs(c.progress(at: t0 + 1200) - c.progress(at: t0 + 900) - c.pause / c.total) < 1e-9)
        #expect(abs(c.progress(at: t0 + 8700) - c.progress(at: t0 + 1500) - c.pause / c.total) < 1e-9)
        // 빈 시간 안의 시각은 다음 구간 시작으로
        #expect(c.progress(at: t0 + 5000) == c.progress(at: t0 + 8700))
        #expect(c.progress(at: t0 - 100) == 0)
        #expect(c.progress(at: t0 + 99999) == 1)
        // 왕복
        for s in [0.0, 300, 900, 1200, 1499, 8700, 9000, 9300] {
            #expect(abs(c.time(at: c.progress(at: t0 + s))!.timeIntervalSince(t0 + s)) < 1e-3, "\(s)")
        }
        // 빈 시간 재생 동안에는 앞 구간 끝에 머문다
        let mid = (900 + c.pause / 2) / c.total
        #expect(c.time(at: mid) == t0 + 900)
        #expect(PlayClock([]).time(at: 0.5) == nil)
    }

    @Test func projectionRoundTrip() throws {
        let map = try #require(SlopeMap.load(resortId: "high1"))
        let rect = CGRect(x: 16, y: 110, width: 398, height: 560)
        let p = MapProjection(map, rect: rect)
        let all = map.slopes.flatMap { $0.lines.flatMap { $0 } } + map.lifts.flatMap(\.line)
        for c in all {
            let pt = p.point(c[0], c[1])
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(pt))
            let back = p.coordinate(pt)
            #expect(abs(back.lat - c[0]) < 1e-9 && abs(back.lon - c[1]) < 1e-9)
        }
        // 비율을 지켜 한 변에 꽉 찬다
        let xs = all.map { p.point($0[0], $0[1]).x }, ys = all.map { p.point($0[0], $0[1]).y }
        #expect(abs(xs.max()! - xs.min()! - rect.width) < 0.01 || abs(ys.max()! - ys.min()! - rect.height) < 0.01)
        #expect(map.isDrawable)
    }

    /// 시트를 25% → 50%로 올려도 축척은 같고 가운데만 위로 간다
    @Test func sheetKeepsScale() throws {
        let map = try #require(SlopeMap.load(resortId: "high1"))
        let size = CGSize(width: 440, height: 956)
        let a = MapProjection(map, rect: DayMapView.fitRect(size, sheetHeight: size.height * 0.25))
        let b = MapProjection(map, rect: DayMapView.fitRect(size, sheetHeight: size.height * 0.5))
        let l = try #require(map.lifts.first?.line)
        func d(_ p: MapProjection) -> Double { hypot(p.point(l[0][0], l[0][1]).x - p.point(l.last![0], l.last![1]).x, p.point(l[0][0], l[0][1]).y - p.point(l.last![0], l.last![1]).y) }
        #expect(abs(d(a) - d(b)) < 1e-6)
        #expect(b.point(l[0][0], l[0][1]).y < a.point(l[0][0], l[0][1]).y)
    }

    /// 안내도처럼 산 위가 화면 위: 모든 내장 리조트에서 리프트 끝(위)이 시작(아래)보다 평균적으로 위에 있다
    @Test func liftsPointUp() throws {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 600)
        for r in Resort.all {
            guard let map = SlopeMap.load(resortId: r.id), !map.lifts.isEmpty else { continue }
            let p = MapProjection(map, rect: rect)
            let dy = map.lifts.compactMap { l -> Double? in
                guard let a = l.line.first, let b = l.line.last else { return nil }
                return p.point(b[0], b[1]).y - p.point(a[0], a[1]).y
            }.reduce(0, +)
            #expect(dy < 0, "\(r.id)")
        }
    }

    /// 12초 × 30fps = 360프레임, 길이 12초 세로 H.264
    @Test func videoFramesAndDuration() async throws {
        let map = try #require(SlopeMap.load(resortId: "high1"))
        let route = [seg(.lift, 0, 600), seg(.run, 600, 900), seg(.run, 4000, 4300)]
        let c = ShareVideo.Content(drawing: DayMapDrawing(map: map, route: route, showNames: true, dark: false), clock: PlayClock(route),
                                   title: "11월 7일 · 하이원", count: "2회", summary: "1.2km")
        let url = try await ShareVideo.make(c, size: CGSize(width: 180, height: 320))
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        #expect(abs(try await asset.load(.duration).seconds - 12) < 0.01)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 180, height: 320))
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        reader.startReading()
        var frames = 0
        while let s = out.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(s) > 0 { frames += 1 } }
        #expect(frames == ShareVideo.seconds * ShareVideo.fps)
    }

    /// 취소하면 임시 파일을 남기지 않는다
    @Test func videoCancelRemovesFile() async throws {
        let map = try #require(SlopeMap.load(resortId: "high1"))
        let c = ShareVideo.Content(drawing: DayMapDrawing(map: map, route: [seg(.run, 0, 600)], showNames: false, dark: true),
                                   clock: PlayClock([seg(.run, 0, 600)]), title: "", count: "", summary: "")
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))
        let task = Task { try await ShareVideo.make(c, size: CGSize(width: 180, height: 320)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))
        #expect(after.subtracting(before).filter { $0.hasPrefix("SlopeMate-") }.isEmpty)
    }

    /// 차량 재판정 뒤에도 하루의 하강 목록과 지도 경로가 같은 판정에서 나온다. 차량 구간 점은 경로·재생에서 빠진다
    @Test func listAndRouteAgreeAfterVehicle() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try AppDatabase(path: dir.appending(path: "t.sqlite").path)
        var tr = Track()
        let rec = try db.createRecording(resortId: "high1", at: tr.t)
        for _ in 0..<3 { tr.lap() }
        for var p in tr.pts {
            p.recordingId = rec.id
            try db.insert(&p)
        }
        try db.end(rec, at: tr.t, reason: "user")
        try db.refreshCache(rec, map: nil)
        let stale = Stats.Day(date: BusinessDay.start(of: rec.startedAt), resortId: "high1", runs: [], usedGPSAltitude: false)
        #expect(try DayData.load(db, stale, recs: db.recordings(of: stale), map: nil).day.runs.count == 3)

        // 두 번째 하강 전체가 차량 이동으로 판정됨
        let s = rec.startedAt
        let vehicle = DateInterval(start: s + 480 + 300, end: s + 960)
        try db.setVehicle(rec, [vehicle], queriedAt: tr.t + 3600)
        let d = try DayData.load(db, stale, recs: db.recordings(of: stale), map: nil)
        #expect(d.day.runs.count == 2)
        let runSegs = d.route.filter { $0.kind == .run }
        for r in d.day.runs { #expect(runSegs.contains { $0.points.contains { $0.t >= r.start && $0.t <= r.end } }) }
        for seg in runSegs {
            // 첫 점은 앞 조각과 나눈 경계 점
            for p in seg.points.dropFirst() { #expect(d.day.runs.contains { $0.start <= p.t && p.t <= $0.end }) }
        }
        #expect(!d.route.contains { $0.points.contains { vehicle.start < $0.t && $0.t < vehicle.end } })
        #expect(d.clock.spans.count == 2)
        // 재생은 차량 구간을 건너뛴다
        for i in 0...200 {
            let t = try #require(d.clock.time(at: Double(i) / 200))
            #expect(!(vehicle.start < t && t < vehicle.end))
        }
    }
}
