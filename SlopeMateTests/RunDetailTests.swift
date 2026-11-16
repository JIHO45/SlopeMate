import Foundation
import Testing
@testable import SlopeMate

/// S19 하강 상세 계산 (R52, 06-verification).
struct RunDetailTests {
    // 1. 그래프가 하강 구간만, 최고·멈춘 시간이 목록 숫자와 같음
    @Test(arguments: ReplayTests.files) func replayMatchesRun(_ url: URL) throws {
        let file = try RecordingFile.decoder.decode(RecordingFile.self, from: Data(contentsOf: url))
        let vehicle = file.vehicle.map(\.interval)
        let runs = RunDetector.detect(file.points, vehicle: vehicle).runs
        #expect(!runs.isEmpty)
        for run in runs {
            let s = RunDetail.series(file.points, run: run, vehicle: vehicle)
            let speeds = s.pieces.flatMap(\.speed)
            // 앞뒤를 자른 뒤에도 최고 속도는 남는다
            #expect(abs((speeds.map(\.v).max() ?? 0) - run.maxSpeed) < 1e-6)
            #expect(run.start <= s.start && s.end <= run.end)
            #expect((speeds + s.pieces.flatMap(\.altitude)).allSatisfy { s.start <= $0.t && $0.t <= s.end })
            #expect(s.maxAt != nil)
            // 멈춘 시간 + 움직인 시간 = 자르기 전 조각 길이 합 (멈춘 시간은 하강 전체 기준)
            let raw = RunDetail.series(file.points, run: run, vehicle: vehicle, trim: false)
            let span = raw.pieces.reduce(0) { $0 + $1.speed.last!.t.timeIntervalSince($1.speed[0].t) }
            #expect(abs(raw.stopped + run.movingTime - span) < 1e-6)
            #expect(s.stopped == raw.stopped)
        }
    }

    // 1-1. 위에서 서서 기다린 시간(고도 평평)은 하강에 들어가지만 그래프·재생 구간에서는 뺀다. 멈춘 시간은 그대로
    @Test func trimsWaitAtTop() throws {
        var tr = Track()
        tr.go(300, climb: 300, speed: 3)
        tr.go(60, climb: 0, speed: 0)
        let moveFrom = tr.t
        tr.go(180, climb: -300, speed: 10)
        tr.go(300, climb: 300, speed: 3)
        let run = try #require(RunDetector.detect(tr.pts).runs.first)
        #expect(run.start < moveFrom.addingTimeInterval(-30))
        let s = RunDetail.series(tr.pts, run: run, vehicle: [])
        #expect(abs(s.start.timeIntervalSince(moveFrom)) <= 6) // 고도 창(앞뒤 5초)만큼 번짐
        #expect(s.pieces.flatMap(\.speed).allSatisfy { $0.t >= s.start && $0.t <= s.end })
        #expect(s.stopped >= 58)
    }

    // 1-2. 서 있어도 GPS가 떨려(이웃 점 속도 1m/s 넘음) 속도로는 못 자른다. 고도로 위·아래 정지를 뺀다.
    // 바닥은 평지를 천천히 밀려 내려간다(0.07m/s, 데모 기록 용평 1/22 하강 2와 같은 꼴)
    @Test func trimsJitteryStops() throws {
        var tr = Track()
        func jitter(_ tr: inout Track, _ n: Int, drift: Double = 0) {
            for k in 0..<n { // 2초마다 ±3m 튐(이웃 점 약 3m/s), 측정 속도 1.5m/s, 기압 ±0.6m(가장 낮은 점은 끝 무렵 −1m)
                let (lat, alt) = (tr.lat, tr.alt)
                tr.t += 2
                tr.lat += Double(k % 2 * 2 - 1) * 3 / 111_195
                tr.alt += (k == n - 10 ? -1 : Double(k % 3 - 1) * 0.6) - drift * 2 * Double(k)
                tr.add(speed: 1.5)
                (tr.lat, tr.alt) = (lat, alt)
            }
        }
        tr.go(300, climb: 300, speed: 3)
        jitter(&tr, 60)
        let moveFrom = tr.t
        tr.go(180, climb: -300, speed: 10)
        let moveTo = tr.t
        jitter(&tr, 60, drift: 0.07)
        tr.go(300, climb: 300, speed: 3)
        let run = try #require(RunDetector.detect(tr.pts).runs.first)
        #expect(run.start < moveFrom.addingTimeInterval(-60) && run.end > moveTo.addingTimeInterval(60))
        let s = RunDetail.series(tr.pts, run: run, vehicle: [])
        #expect(abs(s.start.timeIntervalSince(moveFrom)) <= 6)
        #expect(abs(s.end.timeIntervalSince(moveTo)) <= 6)
        #expect(abs((s.pieces.flatMap(\.speed).map(\.v).max() ?? 0) - run.maxSpeed) < 1e-6)
        // 경로도 같은 구간, 양 끝은 보간한 점
        let route = RunDetail.route(Route.build(tr.pts, summary: RunDetector.detect(tr.pts), vehicle: []),
                                    run: RunDetector.Run(start: s.start, end: s.end, distance: 0, drop: 0, maxSpeed: 0, avgSpeed: 0, movingTime: 0))
        #expect(route.first?.points.first?.t == s.start && route.last?.points.last?.t == s.end)
    }

    // 6-1. 경로 자르기: 양 끝을 시각으로 보간
    @Test func routeEnds() {
        let t0 = Date(timeIntervalSince1970: 0)
        let seg = RouteSegment(kind: .run, points: (0..<3).map { RoutePoint(t: t0 + Double($0) * 10, lat: Double($0), lon: 0) })
        let r = RunDetail.route([seg], run: RunDetector.Run(start: t0 + 5, end: t0 + 15, distance: 0, drop: 0, maxSpeed: 0,
                                                             avgSpeed: 0, movingTime: 0))
        #expect(r.first?.points.map(\.lat) == [0.5, 1, 1.5])
        #expect(r.first?.points.map(\.t) == [t0 + 5, t0 + 10, t0 + 15])
    }

    /// 오르다가 내려오는 중간에 수신 재시작
    static func restartTrack() -> Track {
        var tr = Track()
        tr.go(300, climb: 300, speed: 3)
        tr.go(90, climb: -150, speed: 10)
        tr.restart()
        tr.go(90, climb: -150, speed: 10)
        tr.go(300, climb: 300, speed: 3)
        return tr
    }

    // 2. 기록 없음에서 끊김: 그래프와 3D 경로가 같은 자리에서
    @Test func breaksAtRestart() throws {
        let tr = Self.restartTrack()
        let summary = RunDetector.detect(tr.pts)
        let run = try #require(summary.runs.first)
        #expect(summary.runs.count == 1)
        let s = RunDetail.series(tr.pts, run: run, vehicle: [])
        #expect(s.pieces.count == 2)
        #expect(s.gaps.count == 1)
        let route = RunDetail.route(Route.build(tr.pts, summary: summary, vehicle: []), run: run)
        #expect(route.count == s.pieces.count)
        #expect(route.allSatisfy { $0.kind == .run && $0.points.allSatisfy { run.start <= $0.t && $0.t <= run.end } })
    }

    // 3. 고도: 기압 상대고도 + GPS 중앙값 보정, GPS만이면 정확도 낮음
    @Test func altitude() throws {
        var tr = Track()
        tr.lap()
        tr.pts[3].gpsAlt = 5000      // 튀는 GPS 고도 하나
        let run = try #require(RunDetector.detect(tr.pts).runs.first)
        let s = RunDetail.series(tr.pts, run: run, vehicle: [])
        let alt = s.pieces.flatMap(\.altitude)
        #expect(abs(alt.first!.v - alt.last!.v - run.drop) < 1e-9)
        // Track은 GPS 고도 = 기압 고도 + 700
        #expect(abs(alt.first!.v - (tr.pts.first { $0.t == alt.first!.t }!.baroAlt! + 700)) < 1e-9)
        #expect(!s.lowAccuracy)
        #expect(s.altitudeRange == alt.map(\.v).min()!...alt.map(\.v).max()!)

        var gps = Track()
        gps.baro = false
        gps.lap()
        let gRun = try #require(RunDetector.detect(gps.pts).runs.first)
        #expect(RunDetail.series(gps.pts, run: gRun, vehicle: []).lowAccuracy)
    }

    // 4. 지금 값: 조각 안 보간, 끊긴 구간 nil, 가로 위치 양 끝
    @Test func valueAt() throws {
        let tr = Self.restartTrack()
        let run = try #require(RunDetector.detect(tr.pts).runs.first)
        let s = RunDetail.series(tr.pts, run: run, vehicle: [])
        let a = s.pieces[0].altitude
        let mid = a[1].t.addingTimeInterval(a[2].t.timeIntervalSince(a[1].t) / 2)
        #expect(abs(s.altitude(at: mid)! - (a[1].v + a[2].v) / 2) < 1e-9)
        #expect(s.speed(at: s.pieces[0].speed[1].t) == s.pieces[0].speed[1].v)
        let gap = s.gaps[0]
        #expect(s.speed(at: gap.start.addingTimeInterval(gap.duration / 2)) == nil)
        #expect(s.altitude(at: gap.start.addingTimeInterval(gap.duration / 2)) == nil)
        #expect(s.speed(at: run.start.addingTimeInterval(-1)) == nil)
        #expect(s.x(run.start) == 0 && s.x(run.end) == 1)
        #expect(s.x(run.end.addingTimeInterval(60)) == 1)
    }

    // 5. 이번 시즌 이 슬로프: 시즌 전체, 보고 있는 하강 자리
    @Test func history() {
        let dec = HomeData.seoul.date(from: DateComponents(year: 2026, month: 12, day: 10, hour: 10))!
        func run(_ day: Int, _ slope: String?, _ max: Double, hour: Double = 0) -> RunDetector.Run {
            let t = dec.addingTimeInterval(Double(day) * 86_400 + hour * 3600)
            return RunDetector.Run(start: t, end: t + 120, distance: 1000, drop: 300, maxSpeed: max, avgSpeed: max / 2,
                                   movingTime: 100, slopeId: slope)
        }
        func day(_ runs: [RunDetector.Run], resort: String = "a") -> Stats.Day {
            Stats.Day(date: BusinessDay.start(of: runs[0].start), resortId: resort, runs: runs, usedGPSAltitude: false)
        }
        let first = run(0, "s1", 10), mine = run(1, "s1", 20), later = run(2, "s1", 30)
        let days = [
            day([first, run(0, "s2", 99, hour: 1)]),
            day([mine]),
            day([later]),
            day([run(3, "s1", 99)], resort: "b"),                                   // 다른 리조트
            Stats.Day(date: BusinessDay.start(of: dec.addingTimeInterval(-60 * 86_400)), resortId: "a",
                      runs: [run(-60, "s1", 99)], usedGPSAltitude: false),           // 지난 시즌(10월)
        ]
        let h = RunDetail.history(seasonDays: days, resortId: "a", run: mine, namesShown: true)
        #expect(h == RunDetail.History(maxSpeeds: [10, 20, 30], avgSpeeds: [5, 10, 15], bestIndex: 2, index: 1))
        #expect(RunDetail.history(seasonDays: days, resortId: "a", run: first, namesShown: true)?.index == 0)
        #expect(RunDetail.history(seasonDays: days, resortId: "a", run: mine, namesShown: false) == nil)
        var noSlope = mine
        noSlope.slopeId = nil
        #expect(RunDetail.history(seasonDays: days, resortId: "a", run: noSlope, namesShown: true) == nil)
        let only = RunDetail.history(seasonDays: [day([later])], resortId: "a", run: later, namesShown: true)
        #expect(only?.count == 1 && only?.index == 0)
    }

    // 6. 기록 없음 글
    @Test func gapText() {
        let t = HomeData.seoul.date(from: DateComponents(year: 2026, month: 12, day: 10, hour: 10, minute: 38, second: 10))!
        #expect(RunDetail.gapText([]) == nil)
        #expect(RunDetail.gapText([DateInterval(start: t, end: t + 60)]) == "기록 없음 10:38~10:39")
        #expect(RunDetail.gapText([DateInterval(start: t, end: t + 20)]) == "기록 없음 10:38")
        #expect(RunDetail.gapText([DateInterval(start: t, end: t + 60), DateInterval(start: t + 120, end: t + 130)])
                == "기록 없음 10:38~10:39 외 1")
    }

    @Test func speedTicks() {
        #expect(RunDetail.speedTicks(max: 61) == [0, 30, 60])
        #expect(RunDetail.speedTicks(max: 130) == [0, 60, 120])
        #expect(RunDetail.speedTicks(max: 25) == [0, 10, 20])
    }

    /// 3D 장소 이름(용평 실제 리프트 좌표): 하나로 정해질 때만, 모호하면 앞뒤 리프트 구간으로 가리고, 그래도 아니면 nil
    @Test func placeNames() throws {
        let lifts = try #require(SlopeMap.load(resortId: "yongpyong")).lifts
        let t0 = Date(timeIntervalSince1970: 0)
        func p(_ lat: Double, _ lon: Double, _ s: Double) -> RoutePoint { RoutePoint(t: t0 + s, lat: lat, lon: lon) }
        let run = [p(37.61195, 128.67190, 100), p(37.63000, 128.68000, 200), p(37.63850, 128.68700, 300)]
        // 레인보우 곤돌라 하차장 옆 출발이지만 레인보우 리프트 하차장도 52m: 직전 리프트 구간이 없으면 모호
        #expect(RunDetail.placeNames(run: run, day: [], lifts: lifts).start == nil)
        let gondola = RouteSegment(kind: .lift, points: [p(37.64398, 128.67877, 0), p(37.61191, 128.67188, 90)])
        #expect(RunDetail.placeNames(run: run, day: [gondola], lifts: lifts).start == "출발 · 레인보우 곤돌라")
        // 도착: 골드·뉴골드·브릿지 탑승장이 모여 있어 직후 구간(뉴골드 하차장에서 끝남)으로 가린다
        #expect(RunDetail.placeNames(run: run, day: [gondola], lifts: lifts).end == nil)
        let newGold = RouteSegment(kind: .lift, points: [p(37.63842, 128.68667, 400), p(37.63214, 128.68551, 700)])
        #expect(RunDetail.placeNames(run: run, day: [gondola, newGold], lifts: lifts).end == "도착 · 뉴골드 리프트 탑승장")
        // 직전 탑승이 10분 넘게 떨어져 있으면 가리는 데 쓰지 않는다
        let stale = RouteSegment(kind: .lift, points: [p(37.64398, 128.67877, -900), p(37.61191, 128.67188, -800)])
        #expect(RunDetail.placeNames(run: run, day: [stale], lifts: lifts).start == nil)
        // 이름 없는 리프트(l11) 하차장 옆 출발은 nil
        #expect(RunDetail.placeNames(run: [p(37.63998, 128.68023, 0), p(37.63500, 128.68000, 60)], day: [], lifts: lifts).start == nil)
        // 반경 밖이면 nil
        let far = [p(37.62500, 128.67700, 0), p(37.62000, 128.67800, 60)]
        #expect(RunDetail.placeNames(run: far, day: [gondola, newGold], lifts: lifts) == (nil, nil))
    }
}
