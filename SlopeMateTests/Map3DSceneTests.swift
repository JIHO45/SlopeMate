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
    static func scene(view3D: Resort.View3D? = nil) throws -> Map3DScene {
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
        return Map3DScene(space: s, terrain: Map3DTerrain(space: s, map: m), map: m, route: [], dark: false, viewport: T.viewport, view3D: view3D)
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
}
