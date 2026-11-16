import Foundation
import SceneKit
import Testing
import simd
@testable import SlopeMate

/// S6 3D 장면 v5: 지도 표시, 난이도 색 선, 처음 시점, 날아 들어오기 (R50, K; 05-design 4장 "화면용 3D 보기")
@MainActor
struct Map3DSceneTests {
    typealias T = Terrain3DTests

    /// 북쪽 리프트 하나 + 난이도가 다른 슬로프 넷(초급 둘, 상급, 정보 없음)
    static func scene(view3D: Resort.View3D? = nil, route: [RouteSegment] = [], fitPoints: [(lat: Double, lon: Double)]? = nil) throws -> Map3DScene {
        func line(_ c: Double) -> [[Double]] { [(4.0, c), (16.0, c)].map { let p = T.ll($0.0, $0.1); return [p.lat, p.lon] } }
        let json: [String: Any] = [
            "resort_id": "test", "source": "test", "osm_timestamp": "",
            "slopes": [("easy", 6.0), ("novice", 8.0), ("advanced", 12.0), ("", 14.0)].enumerated().map { i, s in
                var d: [String: Any] = ["id": "s\(i)", "osm_ids": [String](), "lines": [line(s.1)]]
                if !s.0.isEmpty { d["difficulty"] = s.0 }   // 마지막은 난이도 없음
                return d
            },
            "lifts": [["id": "l0", "osm_id": "", "kind": "chair_lift", "line": Array(line(10).reversed())]],
        ]
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let m = try d.decode(SlopeMap.self, from: JSONSerialization.data(withJSONObject: json))
        let s = Terrain3D(terrain: T.grid(T.plane), map: m)
        return Map3DScene(space: s, terrain: Map3DTerrain(space: s, map: m), map: m, route: route, dark: false, viewport: T.viewport, view3D: view3D,
                          fitPoints: fitPoints)
    }

    static func node(_ scene: Map3DScene, _ name: String) throws -> SCNNode {
        try #require(scene.scene.rootNode.childNode(withName: name, recursively: false))
    }

    /// 슬로프 끔: 색 선만, 리프트 끔: 점선과 승·하차장 점. 지형은 그대로
    @Test func setLayersHidesNodes() throws {
        let scene = try Self.scene()
        let slopes = try Self.node(scene, "slopes"), lifts = try Self.node(scene, "lifts"), stations = try Self.node(scene, "stations")
        #expect(!slopes.isHidden && !lifts.isHidden && !stations.isHidden)
        #expect(stations.childNodes.count == 2)
        scene.setLayers(MapLayers(slopes: false, lifts: true))
        #expect(slopes.isHidden && !lifts.isHidden && !stations.isHidden)
        scene.setLayers(.none)
        #expect(slopes.isHidden && lifts.isHidden && stations.isHidden)
        let terrain = scene.scene.rootNode.childNodes.filter { $0.renderingOrder == Map3DScene.Order.terrain }
        #expect(terrain.count == 1 && !terrain[0].isHidden)
        scene.setLayers(MapLayers())
        #expect(!slopes.isHidden && !lifts.isHidden && !stations.isHidden)
    }

    /// 단계마다 지오메트리 하나: 초급(둘이 하나로)·상급·정보 없음 = 3개, 색은 밝게 값
    @Test func slopeNodesPerLevel() throws {
        let scene = try Self.scene()
        let nodes = try Self.node(scene, "slopes").childNodes
        #expect(nodes.count == SlopeStyle.Level.allCases.count)
        let drawn = nodes.filter { $0.geometry != nil }
        #expect(drawn.count == 3)
        #expect(drawn.allSatisfy { $0.renderingOrder == Map3DScene.Order.slope })
        let colors = drawn.compactMap { $0.geometry?.firstMaterial?.diffuse.contents as? UIColor }
        #expect(Set(colors) == Set([SlopeStyle.color(difficulty: "easy", dark: false), SlopeStyle.color(difficulty: "advanced", dark: false),
                                    SlopeStyle.color(difficulty: nil, dark: false)]))
    }

    @Test func homePitch() throws {
        let scene = try Self.scene()
        let deg34 = Float(34 * Double.pi / 180)
        #expect(abs(Camera3D.home(scene.space, viewport: T.viewport).pitch - deg34) < 1e-5)
        // 처음 시점은 42도, yaw 0 고정
        #expect(abs(Map3DScene.startPitch - 42 * .pi / 180) < 1e-5)
        #expect(abs(scene.camera.pitch - Map3DScene.startPitch) < 1e-5 && scene.camera.yaw == 0)
    }

    /// 리조트별 view3D: yaw·pitch(도)를 처음 시점에 쓰고, excludeLifts 리프트 점은 맞춤에서 뺀다
    @Test func view3D() throws {
        let scene = try Self.scene(view3D: .init(yaw: 5, pitch: 50))
        #expect(abs(scene.camera.pitch - 50 * .pi / 180) < 1e-5 && abs(scene.camera.yaw - 5 * .pi / 180) < 1e-5)
        #expect(abs(try Self.scene(view3D: .init(pitch: 80)).camera.pitch - 60 * .pi / 180) < 1e-5)
        // 리프트 l0는 점 2개
        let all = try Self.scene().linePoints.count
        #expect(try Self.scene(view3D: .init(excludeLifts: ["l0"])).linePoints.count == all - 2)
        #expect(try Self.scene(view3D: .init(excludeLifts: ["none"])).linePoints.count == all)
    }

    @Test func view3DDecoding() throws {
        let base = #"{"id":"x","name":"x","latitude":0,"longitude":0,"homePageURL":"https://a.b","slopeStatusURL":"https://a.b","webCamURL":null"#
        let d = JSONDecoder()
        #expect(try d.decode(Resort.self, from: Data((base + "}").utf8)).view3D == nil)
        let r = try d.decode(Resort.self, from: Data((base + #","view3D":{"yaw":5}}"#).utf8))
        #expect(r.view3D?.yaw == 5 && r.view3D?.pitch == nil && r.view3D?.excludeLifts == nil && r.view3D?.zoom == nil)
        #expect(try d.decode(Resort.self, from: Data((base + #","view3D":{"zoom":0.8}}"#).utf8)).view3D?.zoom == 0.8)
    }

    /// zoom: 맞춘 거리에 곱한다(0.4~1.5)
    @Test func view3DZoom() throws {
        let d = try Self.scene().camera.distance
        #expect(abs(try Self.scene(view3D: .init(zoom: 0.8)).camera.distance - d * 0.8) < d * 1e-4)
        #expect(abs(try Self.scene(view3D: .init(zoom: 0.1)).camera.distance - d * 0.4) < d * 1e-4)
    }

    static let screens = [CGSize(width: 402, height: 874), CGSize(width: 375, height: 667)]

    /// 내장 12곳 처음 시점: 맞춘 점이 모두 안전 영역 안(±1pt), 점 상자가 영역 폭이나 높이를 채우고(2pt 이하) 가운데(2pt 이하).
    /// 시트 위 선(bottomEdge at 0.5)이 보는 땅은 원 안(edge ≥ startEdge)
    @Test(arguments: Resort.all.map(\.id), [0, 1])
    func startFit(resortId: String, screen: Int) throws {
        let v = Self.screens[screen]
        let t = try #require(Terrain.load(resortId: resortId)), m = try #require(SlopeMap.load(resortId: resortId))
        let s = Terrain3D(terrain: t, map: m)
        let view3D = Resort.all.first { $0.id == resortId }?.view3D
        let scene = Map3DScene(space: s, terrain: Map3DTerrain(space: s, map: m, side: 64), map: m, route: [], dark: false, viewport: v,
                               view3D: view3D)
        let c = scene.camera, top: CGFloat = 150, bottom = v.height * 0.25 + 24
        let area = CGRect(x: 16, y: top + Map3DScene.startPadTop, width: v.width - 32, height: v.height - bottom - top - Map3DScene.startPadTop)
        let pts = scene.linePoints.map { c.screen($0, viewport: v, top: top, bottom: bottom) }
        let lo = CGPoint(x: pts.map(\.x).min()!, y: pts.map(\.y).min()!), hi = CGPoint(x: pts.map(\.x).max()!, y: pts.map(\.y).max()!)
        let label = "\(resortId) \(Int(v.width))x\(Int(v.height))"
        // zoom < 1이면 상자가 영역보다 크다(가운데만 본다)
        if (view3D?.zoom ?? 1) >= 1 {
            #expect(lo.x >= area.minX - 1 && lo.y >= area.minY - 1 && hi.x <= area.maxX + 1 && hi.y <= area.maxY + 1, "\(label) \(lo) \(hi) \(area)")
        }
        if view3D?.zoom ?? 1 == 1 {
            #expect(min(area.width - (hi.x - lo.x), area.height - (hi.y - lo.y)) <= 2, "\(label) \(lo) \(hi) \(area)")
        }
        #expect(hypot((lo.x + hi.x) / 2 - area.midX, (lo.y + hi.y) / 2 - area.midY) <= 2, "\(label) \(lo) \(hi) \(area)")
        let shift = Float(v.height / 2 - (top + (v.height - top - bottom) / 2)) * c.metersPerPoint(viewportHeight: v.height)
        let edge = c.bottomEdge(s, drop: shift, at: 0.5)
        print("startFit \(label) pitch \(c.pitch * 180 / .pi) distance \(c.distance) edge0.5 \(edge)")
        #expect(edge >= Map3DScene.startEdge, "\(label) edge \(edge)")
    }

    /// 0: 처음 시점에서 yaw +0.38, pitch 62도, 거리 1.35배(제한 안). 1: 처음 시점 그대로
    @Test func flyIn() throws {
        let scene = try Self.scene()
        let start = scene.camera
        scene.setFlyIn(progress: 0)
        let c = scene.camera
        #expect(abs(c.yaw - (start.yaw + 0.38)) < 1e-5)
        #expect(abs(c.pitch - 62 * .pi / 180) < 1e-5)
        let limit = Camera3D.home(scene.space, viewport: T.viewport).distance * Camera3D.zoomRange.upperBound
        #expect(abs(c.distance - min(start.distance * 1.35, limit)) < 1e-2)
        scene.setFlyIn(progress: 0.5)
        #expect(scene.camera.pitch < c.pitch && scene.camera.pitch > start.pitch)
        scene.setFlyIn(progress: 1)
        #expect(scene.camera == start)
    }

    /// S19: fitPoints를 주면 처음 시점이 그 점들(하강 하나)에 맞춰져 안전 영역 안에 들어오고 더 가깝다. view3D.zoom은 곱하지 않는다. 안 주면 그대로
    @Test func fitPoints() throws {
        let run = [(9.0, 7.0), (10.0, 7.5), (11.0, 7.2), (12.0, 8.0)].map { T.ll($0.0, $0.1) }
        let base = try Self.scene(), scene = try Self.scene(fitPoints: run)
        #expect(scene.linePoints.count == run.count)
        #expect(scene.camera.distance < base.camera.distance)
        let v = T.viewport, top: CGFloat = 150, bottom = v.height * 0.25 + 24
        let area = CGRect(x: 16, y: top + Map3DScene.startPadTop, width: v.width - 32, height: v.height - bottom - top - Map3DScene.startPadTop)
        for p in scene.linePoints {
            let s = scene.camera.screen(p, viewport: v, top: top, bottom: bottom)
            #expect(area.insetBy(dx: -1, dy: -1).contains(s), "\(s) \(area)")
        }
        #expect(try Self.scene(view3D: .init(zoom: 0.8), fitPoints: run).camera == scene.camera)
        #expect(try Self.scene(fitPoints: nil).camera == base.camera)
    }

    /// S19 진입은 pitch 55도(리조트 view3D.pitch는 무시, 방위는 그대로)
    @Test func runEntryPitch() throws {
        let run = [(9.0, 7.0), (12.0, 8.0)].map { T.ll($0.0, $0.1) }
        let scene = try Self.scene(view3D: .init(yaw: 5, pitch: 40), fitPoints: run)
        #expect(abs(scene.camera.pitch - Map3DScene.runPitch) < 1e-5 && abs(scene.camera.yaw - 5 * .pi / 180) < 1e-5)
    }

    /// 추적 카메라: 직선이면 진행 반대편에서 보고, 90도 굽이에서는 한 걸음에 초당 40도까지만 돌며, 359도→1도는 짧은 쪽으로
    @Test func followCamera() {
        var c = Camera3D(target: .zero, distance: 450, yaw: 0, pitch: 0.7)
        // 북쪽(−z)으로 진행: 카메라는 남쪽(+z) 뒤, yaw 0
        for _ in 0..<200 { c = Camera3D.follow(from: c, dot: .zero, ahead: SIMD3(0, 0, -120), dt: 1.0 / 30) }
        #expect(abs(c.yaw) < 0.01 && c.position.z > 0)
        // 동쪽(+x)으로 꺾임: 원하는 yaw −90도. 한 걸음 변화는 40도/초 × dt 이하
        let n = Camera3D.follow(from: c, dot: .zero, ahead: SIMD3(120, 0, 0), dt: 1.0 / 30)
        #expect(abs(n.yaw - c.yaw) <= Camera3D.followMaxTurn / 30 + 1e-5 && n.yaw < c.yaw)
        var t = c
        for _ in 0..<300 { t = Camera3D.follow(from: t, dot: .zero, ahead: SIMD3(120, 0, 0), dt: 1.0 / 30) }
        #expect(abs(t.yaw + .pi / 2) < 0.02 && t.position.x < 0)
        // 감김: 359.5도에서 1도 쪽으로는 +1.5도만 돈다(반대로 358.5도 돌지 않는다)
        let w = Camera3D.follow(from: Camera3D(target: .zero, distance: 450, yaw: -0.5 * .pi / 180, pitch: 0.7),
                                dot: .zero, ahead: SIMD3(-sin(1 * .pi / 180), 0, -cos(1 * .pi / 180)) * 120, dt: 0.1, tau: 0.0001, maxTurn: 10)
        #expect(abs(w.yaw - 1 * .pi / 180) < 1e-3)
    }

    /// 앞 점: 경로를 따라 잰 거리(직선 거리 아님), 남은 거리가 모자라면 도착점
    @Test func aheadAlongPath() {
        let t0 = Date(timeIntervalSince1970: 0)
        // ㄱ자 경로: 동쪽 100m, 북쪽 100m
        let path: [(t: Date, p: SIMD3<Float>)] = [(t0, SIMD3(0, 0, 0)), (t0 + 10, SIMD3(100, 0, 0)), (t0 + 20, SIMD3(100, 0, -100))]
        let dist: [Float] = [0, 100, 200]
        let a = Map3DScene.ahead(path: path, dist: dist, at: t0, by: 120)
        #expect(simd_distance(a, SIMD3(100, 0, -20)) < 1e-3)
        let b = Map3DScene.ahead(path: path, dist: dist, at: t0 + 5, by: 120)   // 50m 지점 + 120 = 170
        #expect(simd_distance(b, SIMD3(100, 0, -70)) < 1e-3)
        #expect(Map3DScene.ahead(path: path, dist: dist, at: t0 + 15, by: 120) == SIMD3(100, 0, -100))
        #expect(Map3DScene.ahead(path: path, dist: dist, at: t0, by: -60) == SIMD3(0, 0, 0))   // 뒤 점은 출발점에서 멈춘다
        #expect(simd_distance(Map3DScene.ahead(path: path, dist: dist, at: t0 + 15, by: -60), SIMD3(90, 0, 0)) < 1e-3)
    }

    /// 장면에서 재생을 따라가면 카메라가 추적 거리 쪽으로 가까워진다(리조트 전체 최소 거리에 막히지 않음). 손짓하면 멈추고, 처음 시점 버튼에서 다시 켠다
    @Test func sceneFollows() throws {
        let t0 = Date(timeIntervalSince1970: 0)
        let pts = (0...40).map { i in let p = T.ll(16 - Double(i) * 0.3, 8 + Double(i % 7) * 0.1); return RoutePoint(t: t0 + Double(i) * 5, lat: p.lat, lon: p.lon) }
        let s = try Self.scene(route: [RouteSegment(kind: .run, points: pts)], fitPoints: pts.map { (lat: $0.lat, lon: $0.lon) })
        let start = s.camera.distance
        for i in 0..<200 { s.setPlayback(t0 + Double(i) * 0.5, clock: Double(i) / 10) }
        #expect(s.isFollowing && s.camera.distance < start && abs(s.camera.pitch - Camera3D.followPitch) < 0.1, "\(s.camera)")
        s.stopFollowing()
        #expect(!s.isFollowing)
        s.resetCamera(animated: false)
        #expect(s.isFollowing)
    }

    /// 급한 지그재그(머리핀 6번)를 실제 재생 속도(약 210m/s, 하강 4km를 20초)로 따라갈 때 점이 시트 위 보이는 영역 안쪽 16pt를 벗어나지 않는다.
    /// 목표점 τ가 1.2초면 굽이에서 점이 위 가장자리 밖으로 밀린다(용평 하강 14 측정, followTargetTau 주석)
    @Test func followKeepsDotInView() throws {
        let t0 = Date(timeIntervalSince1970: 0)
        var pts: [RoutePoint] = []
        for leg in 0..<6 {
            for k in 0...16 {
                let c = leg % 2 == 0 ? 2 + Double(k) : 18 - Double(k)
                let p = T.ll(3 + Double(leg) * 2.6 + Double(k) * 0.05, c)
                pts.append(RoutePoint(t: t0 + Double(pts.count), lat: p.lat, lon: p.lon))   // 약 25m 간격, 기록상 1초
            }
        }
        let s = try Self.scene(route: [RouteSegment(kind: .run, points: pts)], fitPoints: pts.map { (lat: $0.lat, lon: $0.lon) })
        let top: CGFloat = 150, bottom: CGFloat = 220
        s.setViewport(T.viewport, topInset: top, bottomInset: bottom, animated: false)
        let area = CGRect(x: 0, y: top, width: T.viewport.width, height: T.viewport.height - top - bottom).insetBy(dx: 16, dy: 16)
        var worst: CGPoint?
        for f in 0..<Int(Double(pts.count - 1) / 0.28) {
            s.setPlayback(t0 + Double(f) * 0.28, clock: Double(f) / 30)   // 프레임마다 기록 0.28초 ≈ 7m → 30fps에서 약 210m/s
            guard f >= 30, let dot = s.dot else { continue }   // 진입 시점에서 넘어오는 첫 1초는 뺀다
            let p = s.camera.screen(dot, viewport: T.viewport, top: top, bottom: bottom)
            if !area.contains(p), worst == nil { worst = p }
        }
        #expect(worst == nil, "\(String(describing: worst)) \(area)")
    }

    /// 재생 점 화살촉: 위로 가면 0, 오른쪽이면 -90도(시계), 왼쪽 +90도, 1pt 미만이면 그대로(nil)
    @Test func arrowAngle() {
        let o = CGPoint(x: 100, y: 100)
        #expect(Map3DScene.arrowAngle(from: o, to: CGPoint(x: 100, y: 90)) == 0)
        #expect(abs(Map3DScene.arrowAngle(from: o, to: CGPoint(x: 110, y: 100))! + .pi / 2) < 1e-5)
        #expect(abs(Map3DScene.arrowAngle(from: o, to: CGPoint(x: 90, y: 100))! - .pi / 2) < 1e-5)
        #expect(Map3DScene.arrowAngle(from: o, to: CGPoint(x: 100.5, y: 100.5)) == nil)
    }

    /// 장소 이름표 숨김: 재생 점 16pt 안·반대 표식 8pt 안·보이는 영역 밖이면 숨김
    @Test func labelHidden() {
        let visible = CGRect(x: 8, y: 150, width: 377, height: 400)
        let r = Map3DScene.labelRect(at: CGPoint(x: 200, y: 300), size: CGSize(width: 100, height: 24))
        #expect(r == CGRect(x: 150, y: 266, width: 100, height: 24))
        #expect(!Map3DScene.labelHidden(r, dot: nil, other: nil, visible: visible))
        #expect(Map3DScene.labelHidden(r, dot: CGPoint(x: 265, y: 270), other: nil, visible: visible))
        #expect(!Map3DScene.labelHidden(r, dot: CGPoint(x: 267, y: 270), other: nil, visible: visible))
        #expect(Map3DScene.labelHidden(r, dot: nil, other: CGPoint(x: 143, y: 280), visible: visible))
        #expect(!Map3DScene.labelHidden(r, dot: nil, other: CGPoint(x: 141, y: 280), visible: visible))
        #expect(Map3DScene.labelHidden(Map3DScene.labelRect(at: CGPoint(x: 200, y: 170), size: CGSize(width: 100, height: 24)), dot: nil, other: nil, visible: visible))
    }

    /// S19 2D 고정 시점(RunDetailView.frame): 점 상자가 영역 가운데에 들어오고 한 변을 채운다. 최대 8배, 점이 없으면 fit을 영역에
    @Test func runDetailFrame() {
        let area = CGRect(x: 32, y: 126, width: 300, height: 400)
        let pts = [CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 300)]
        let t = RunDetailView.frame(pts, in: area, fit: .zero)
        let a = pts[0].applying(t), b = pts[1].applying(t)
        #expect(abs((a.x + b.x) / 2 - area.midX) < 1e-6 && abs((a.y + b.y) / 2 - area.midY) < 1e-6)
        #expect(abs(abs(b.y - a.y) - area.height) < 1e-6 && abs(b.x - a.x) <= area.width)
        #expect(abs(RunDetailView.frame([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], in: area, fit: .zero).a - 8) < 1e-9)
        let fit = CGRect(x: 0, y: 0, width: 600, height: 400)
        #expect(CGPoint(x: fit.midX, y: fit.midY).applying(RunDetailView.frame([], in: area, fit: fit)) == CGPoint(x: area.midX, y: area.midY))
    }

    @Test func objectParticle() {
        #expect(RunDetailView.objectParticle("레인보우 1") == "을")
        #expect(RunDetailView.objectParticle("하강 2") == "를")
        #expect(RunDetailView.objectParticle("제우스") == "를")
        #expect(RunDetailView.objectParticle("빅토리아") == "를")
        #expect(RunDetailView.objectParticle("헤라") == "를")
        #expect(RunDetailView.objectParticle("아테나 3") == "을")
    }
}
