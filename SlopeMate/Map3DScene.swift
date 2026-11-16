import SceneKit
import simd
import UIKit

/// 카메라 값. 순수 계산이라 테스트한다 (05-design 4장 "화면용 3D 보기")
nonisolated struct Camera3D: Equatable, Sendable {
    var target: SIMD3<Float>    // 바라보는 점
    var distance: Float         // target까지 m
    var yaw: Float              // 라디안. 0 = 처음 방향(카메라가 +z 쪽). 커지면 카메라가 +x 쪽으로 돈다
    var pitch: Float            // 라디안. 수평에서 내려다보는 각

    static let fovY: Float = 30 * .pi / 180
    static let pitchRange: ClosedRange<Float> = (20 * .pi / 180)...(80 * .pi / 180)
    /// 구 전체 시점(거리 제한 기준)의 각도이자 손짓 때 격자 경계 보정 상한(34도). 처음 시점은 Map3DScene.startPitch(42도)
    static let homePitch: Float = 34 * .pi / 180
    /// 거리 제한: 처음 거리의 0.15~1.3배
    static let zoomRange: ClosedRange<Float> = 0.15...1.3

    /// 처음 시점. viewport는 화면 전체 크기(pt). 2D fitRect와 같은 여백으로 구가 들어오는 거리
    static func home(_ space: Terrain3D, viewport: CGSize) -> Camera3D {
        // 위 150, 좌우 16, 아래 25% 시트 + 24
        let H = max(Float(viewport.height), 1), W = Float(viewport.width)
        let h = max(80, H - 150 - (H * 0.25 + 24)), w = max(1, W - 32)
        let k = min(w, h) / H   // 구 지름이 화면 높이에서 차지할 비율
        let half = atan(tan(fovY / 2) * k)
        return Camera3D(target: space.center, distance: max(space.radius, 1) / sin(half), yaw: 0, pitch: homePitch)
    }

    /// 제한을 적용한 값 (pitch, 거리, 목표점 위치·높이, 지형 아래로 내려가지 않기)
    /// minDistance: 가장 가까운 거리(m). nil이면 처음 거리 × 0.15(S19 추적은 따로 준다)
    func clamped(_ space: Terrain3D, home: Camera3D, minDistance: Float? = nil) -> Camera3D {
        var c = self
        c.pitch = min(max(pitch, Self.pitchRange.lowerBound), Self.pitchRange.upperBound)
        c.distance = min(max(distance, minDistance ?? home.distance * Self.zoomRange.lowerBound), home.distance * Self.zoomRange.upperBound)
        let center = SIMD2(space.center.x, space.center.z)
        var xz = SIMD2(target.x, target.z)
        let off = xz - center, len = simd_length(off)
        if len > space.radius, len > 0 { xz = center + off / len * space.radius }
        c.target = SIMD3(xz.x, space.height(xz), xz.y)
        // 카메라가 지형 + 30m 아래면 pitch를 1도씩 올린다
        while c.pitch < Self.pitchRange.upperBound {
            let p = c.position
            if p.y >= space.height(SIMD2(p.x, p.z)) + 30 { break }
            c.pitch = min(Self.pitchRange.upperBound, c.pitch + .pi / 180)
        }
        // 처음 각도(34도)보다 낮게 기울였을 때, 화면 아래 가운데·양 끝이 보는 땅이 격자 가장자리 페이드 안쪽(edge 0.2)이 될 때까지
        // pitch를 1도씩 올린다(최대 34도). 작은 격자(지산)를 낮게 기울이면 격자 경계가 화면 아래에 잘린 면으로 보이기 때문
        // ponytail: 세로 화면 비율 0.46 가정, 화면 아래 시트만큼 내린 시점 이동은 무시(edge 여유로 덮는다)
        while c.pitch < Self.homePitch, c.bottomEdge(space) < 0.2 {
            c.pitch = min(Self.homePitch, c.pitch + .pi / 180)
        }
        return c
    }

    /// 화면 아래 가운데·양 끝 광선이 지형에 닿는 곳의 가장 작은 edge. 광선은 거리의 1/32씩 최대 3배 거리까지 걷는다.
    /// drop: 카메라를 화면 아래 방향으로 옮긴 거리(m, Map3DScene.applyCamera의 shift). at: 화면 가운데→맨 아래 비율(1 = 맨 아래, 0.5 = 시트 위 선)
    func bottomEdge(_ space: Terrain3D, drop: Float = 0, at: Float = 1) -> Float {
        let a = pitch + atan(at * tan(Self.fovY / 2)), f = SIMD2(-sin(yaw), -cos(yaw)), r = SIMD2(cos(yaw), -sin(yaw))
        let down = SIMD3(f.x * cos(a), -sin(a), f.y * cos(a)), side = SIMD3(r.x, 0, r.y) * tan(Self.fovY / 2) * 0.46
        let up = SIMD3(f.x * sin(pitch), cos(pitch), f.y * sin(pitch))
        let step = distance / 32
        return [down, down + side, down - side].map { d in
            let d = simd_normalize(d)
            var p = position - up * drop
            for _ in 0..<96 {
                p += d * step
                if p.y <= space.height(SIMD2(p.x, p.z)) { break }
            }
            return space.edge(SIMD2(p.x, p.z))
        }.min()!
    }

    /// S19 추적 카메라 한 걸음(순수 계산). dot: 재생 점, ahead: 경로를 따라 잰 앞 점(장면 좌표).
    /// 카메라는 dot→ahead 방향의 뒤에서 보고, 목표점은 dot과 ahead 사이. yaw는 최단각으로 지수 평활(τ)하되 초당 maxTurn 라디안까지만,
    /// 거리·pitch도 같은 비율로, 목표점은 targetTau로 더 빨리 다가간다(진입 시점에서 부드럽게 넘어간다). dt는 0.1초로 자른다
    static func follow(from c: Camera3D, dot: SIMD3<Float>, ahead: SIMD3<Float>, back: SIMD3<Float>? = nil, dt: Float,
                       pitch: Float = followPitch, distance: Float = followDistance,
                       tau: Float = 1.2, targetTau: Float = followTargetTau, maxTurn: Float = followMaxTurn) -> Camera3D {
        let dt = min(max(dt, 0), 0.1), a = 1 - exp(-dt / tau)
        // 방향은 back(경로 뒤 점)→ahead. 도착 직전에 앞 점이 가까워져도 저속 GPS 흔들림을 따라 돌지 않는다
        let from = back ?? dot, d = SIMD2(ahead.x - from.x, ahead.z - from.z)
        var n = c
        if simd_length(d) > 1 {
            let want = atan2(-d.x, -d.y)
            var delta = remainder(want - c.yaw, 2 * .pi)
            delta *= a
            delta = min(max(delta, -maxTurn * dt), maxTurn * dt)
            n.yaw = remainder(c.yaw + delta, 2 * .pi)
        }
        n.target += (dot + (ahead - dot) * 0.35 - c.target) * (1 - exp(-dt / targetTau))
        n.distance += (distance - c.distance) * a
        n.pitch += (pitch - c.pitch) * a
        return n
    }
    /// 추적 첫 시험값: pitch 38도(수평 기준), 거리 800m, 앞 점 120m(경로를 따라 잰 거리), 회전 초당 40도.
    /// 목표점 τ 0.4초: 용평 하강 14(4.3km를 20초) 측정에서 1.2초면 굽이에서 점이 위 가장자리 밖으로 42pt 밀렸고(앞보기를 60m로 줄이면 더 나빠지고 회전 60도는 그대로),
    /// 0.4초면 점이 보이는 영역 안쪽 40pt를 벗어나는 프레임 0%
    static let followTargetTau: Float = 0.4
    static let followPitch: Float = 38 * .pi / 180, followDistance: Float = 800, followAhead: Float = 120, followMaxTurn: Float = 40 * .pi / 180

    /// target + distance × (sin yaw · cos pitch, sin pitch, cos yaw · cos pitch)
    var position: SIMD3<Float> {
        target + distance * SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
    }

    /// 장면 점 p의 화면 위치(pt). applyCamera와 같은 투영: 카메라를 보이는 영역(top…H−bottom) 가운데만큼 화면 세로로 옮긴다
    func screen(_ p: SIMD3<Float>, viewport: CGSize, top: CGFloat, bottom: CGFloat) -> CGPoint {
        let H = Float(viewport.height), W = Float(viewport.width), t = tan(Self.fovY / 2)
        let f = simd_normalize(target - position), r = SIMD3(cos(yaw), 0, -sin(yaw)), u = simd_cross(r, f)
        let visibleMid = Float(top) + max(80, H - Float(top) - Float(bottom)) / 2
        let shift = (H / 2 - visibleMid) * metersPerPoint(viewportHeight: viewport.height)
        let v = p - (position - u * shift), z = max(simd_dot(v, f), 1)
        return CGPoint(x: CGFloat(W / 2 + simd_dot(v, r) / (z * t) * H / 2), y: CGFloat(H / 2 - simd_dot(v, u) / (z * t) * H / 2))
    }

    /// 화면 점(pt)이 보는 땅(장면 xz). screen과 같은 투영의 광선을 거리의 1/32씩 3배 거리까지 걷는다. 하늘이면 nil
    func ground(_ pt: CGPoint, viewport: CGSize, top: CGFloat, bottom: CGFloat, space: Terrain3D) -> SIMD2<Float>? {
        let H = Float(viewport.height), W = Float(viewport.width), t = tan(Self.fovY / 2)
        let f = simd_normalize(target - position), r = SIMD3(cos(yaw), 0, -sin(yaw)), u = simd_cross(r, f)
        let visibleMid = Float(top) + max(80, H - Float(top) - Float(bottom)) / 2
        var p = position - u * (H / 2 - visibleMid) * metersPerPoint(viewportHeight: viewport.height)
        let d = simd_normalize(f + r * ((Float(pt.x) - W / 2) / (H / 2) * t) + u * ((H / 2 - Float(pt.y)) / (H / 2) * t)) * (distance / 32)
        for _ in 0..<96 {
            p += d
            if p.y <= space.height(SIMD2(p.x, p.z)) { return SIMD2(p.x, p.z) }
        }
        return nil
    }

    /// 목표점 거리에서 화면 1pt의 길이(m) = 2 · distance · tan(fovY / 2) / viewportHeight
    func metersPerPoint(viewportHeight: CGFloat) -> Float {
        2 * distance * tan(Self.fovY / 2) / max(Float(viewportHeight), 1)
    }
}

/// 3D 지형 준비물: 지오메트리(위치·UV·삼각형)와 지형 질감(Terrain3D.cachedGroundTexture, 밝게·어둡게 같이 씀).
/// 메시·질감이 무거워 메인 스레드 밖(Task.detached)에서 만든다. 장면에 붙기 전에는 다른 스레드로 넘겨도 된다
nonisolated struct Map3DTerrain: @unchecked Sendable {
    let geometry: SCNGeometry
    let texture: CGImage?

    /// side: 질감 긴 변 상한(테스트는 작게)
    init(space: Terrain3D, map: SlopeMap, side: Int = 2048) {
        let mesh = space.mesh()
        geometry = mesh.geometry()
        texture = space.cachedGroundTexture(map: map, mesh: mesh, side: side, canopy: .load(resortId: map.resortId)).image
    }
}

/// S6 3D 장면. 노드·재질·카메라를 가진다. MainActor(프로젝트 기본)
final class Map3DScene {
    let scene: SCNScene
    let cameraNode: SCNNode
    private(set) var camera: Camera3D
    /// 재생 점의 장면 좌표. 점이 없으면 nil (따라가기용)
    private(set) var dot: SIMD3<Float>?

    /// 누르기 투영과 카메라 계산에 쓰는 값
    let space: Terrain3D
    let map: SlopeMap
    private let route: [RouteSegment]
    private var dark: Bool
    /// 구 전체가 들어오는 시점(Camera3D.home). 거리 제한의 기준
    private var limit: Camera3D
    /// 처음 시점: 슬로프·리프트가 보이는 영역을 채운다
    private var start: Camera3D
    /// 슬로프·리프트 점 전부(장면 좌표, view3D.excludeLifts 리프트는 뺌) 또는 fitPoints. 처음 시점 맞춤용
    let linePoints: [SIMD3<Float>]
    /// 리조트별 처음 시점 값(yaw·pitch)
    private let view3D: Resort.View3D?
    /// 리프트 양 끝(승·하차장) [위도, 경도]
    private let stations: [[Double]]
    private var viewport: CGSize
    private var topInset: CGFloat = 150
    private var bottomInset: CGFloat
    private var playback: Date?
    private var highlight: RunDetector.Run?
    /// S19 추적: 하강 점(시각 순, 장면 좌표)과 경로를 따라 잰 누적 거리(m, xz). S6이면 비어 있다
    private let followPath: [(t: Date, p: SIMD3<Float>)]
    private let followDist: [Float]
    /// 손짓하면 끈다. 처음 시점 버튼을 누르거나 재생을 처음부터 다시 하면 다시 켠다
    private var followOn = true
    private var followClock: CFTimeInterval = 0
    /// 지금 재생을 따라 카메라를 움직이는 중(Map3DView의 화면 밖 따라가기는 이때 쉰다)
    var isFollowing: Bool { followOn && !followPath.isEmpty && playback != nil }
    /// 리본을 만들 때의 화면 1pt 길이(m). 15% 넘게 바뀌면 다시 만든다
    private var ribbonMPP: Float = 0

    /// 그리는 순서(05-design 4장 "화면용 3D 보기"): 지형 < 슬로프 색 선 < 리프트 < 승·하차장 점 < 경로 번짐 < 경로 테두리 < 옅은 경로 < 진한 경로 < 강조 테두리 < 강조 < 재생 점
    enum Order {
        static let terrain = -10, slope = -3, lift = -2, station = -1, glow = 0
        static let casing = 3, faded = 4, solid = 5, highlightCasing = 6, highlight = 7, dot = 8
    }

    private let terrainNode = SCNNode(), slopeNode = SCNNode(), liftNode = SCNNode(), stationNode = SCNNode()
    private let routeNode = SCNNode(), highlightNode = SCNNode(), highlightCasingNode = SCNNode(), dotNode = SCNNode()
    /// 난이도 단계별 슬로프 색 선(SlopeStyle.Level.allCases 순서). slopeNode 아래
    private let levelNodes = SlopeStyle.Level.allCases.map { _ in SCNNode() }
    /// 단계별 단색 재질. 눈 띠 위라 밝게·어둡게 모두 밝게 색
    private let levelMats = SlopeStyle.Level.allCases.map { l in
        let m = Map3DScene.flat()
        m.diffuse.contents = Map3DScene.color(SlopeStyle.hex(l, dark: false))
        return m
    }
    private let terrainMat = SCNMaterial(), liftMat = Map3DScene.flat(), stationMat = Map3DScene.flat(), glowMat = Map3DScene.flat()
    private let highlightMat = Map3DScene.flat(), casingMat = Map3DScene.flat(), dotMat = Map3DScene.flat()
    /// 승·하차장 점 판(8pt = 6pt 원 + 테두리 1pt). 화면 1pt 길이로 키운다
    private let stationPlane = SCNPlane(width: 8, height: 8)
    /// 경로 종류별 [진한, 옅은] 재질
    private var routeMats: [RouteSegment.Kind: [SCNMaterial]] = [:]
    /// 경로 조각마다 리본과 두 겹 노드
    private var segments: [(seg: RouteSegment, ribbon: Terrain3D.Ribbon, solid: SCNNode, faded: SCNNode)] = []

    /// route: 하강 0회면 빈 배열. terrain: Map3DTerrain(space, map). viewport: 화면 전체 크기(pt). 카메라는 처음 시점.
    /// fitPoints: 처음 시점을 이 점들(S19 하강 하나)에 맞춘다. 이때 view3D는 yaw·pitch만 쓰고 zoom(리조트 전체용)은 곱하지 않는다
    init(space: Terrain3D, terrain: Map3DTerrain, map: SlopeMap, route: [RouteSegment], dark: Bool, viewport: CGSize,
         view3D: Resort.View3D? = nil, fitPoints: [(lat: Double, lon: Double)]? = nil) {
        self.space = space
        var view3D = view3D
        if fitPoints != nil {
            view3D?.zoom = nil
            // S19 진입: 하강 전체(출발·도착)가 보이는 높은 시점. 리조트 view3D의 방위만 쓴다
            view3D = Resort.View3D(yaw: view3D?.yaw, pitch: Double(Self.runPitch * 180 / .pi), excludeLifts: view3D?.excludeLifts, zoom: nil)
        }
        let path = fitPoints == nil ? [] : route.filter { $0.kind == .run }.flatMap(\.points).sorted { $0.t < $1.t }
            .map { (t: $0.t, p: space.point(lat: $0.lat, lon: $0.lon)) }
        followPath = path
        followDist = path.indices.reduce(into: [Float]()) { acc, i in
            acc.append(i == 0 ? 0 : acc[i - 1] + simd_distance(SIMD2(path[i].p.x, path[i].p.z), SIMD2(path[i - 1].p.x, path[i - 1].p.z)))
        }
        self.view3D = view3D
        self.map = map
        self.route = route
        self.dark = dark
        self.viewport = viewport
        bottomInset = viewport.height * 0.25 + 24
        let excluded = Set(view3D?.excludeLifts ?? [])
        let all = map.slopes.flatMap { $0.lines.flatMap { $0 } } + map.lifts.filter { !excluded.contains($0.id) }.flatMap(\.line)
        linePoints = fitPoints?.map { space.point(lat: $0.lat, lon: $0.lon) } ?? all.map { space.point(lat: $0[0], lon: $0[1]) }
        stations = map.lifts.flatMap { l in [l.line.first, l.line.last].compactMap { $0 } }
        limit = Camera3D.home(space, viewport: viewport)
        start = Self.fit(space, points: linePoints, viewport: viewport, top: 150, bottom: viewport.height * 0.25 + 24, limit: limit, view3D: view3D)
        camera = start
        scene = SCNScene()
        cameraNode = SCNNode()

        let cam = SCNCamera()
        cam.fieldOfView = CGFloat(Camera3D.fovY * 180 / .pi)
        cam.projectionDirection = .vertical
        cam.automaticallyAdjustsZRange = true
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)

        // 지형: 음영을 구운 질감(조명 없음). 모드 색·원형 가장자리·안개는 셰이더(terrainShader). 조명이 없어 장면에 빛을 두지 않는다
        terrainMat.lightingModel = .constant
        terrainMat.diffuse.contents = terrain.texture ?? UIColor.white
        terrainMat.diffuse.wrapS = .clamp
        terrainMat.diffuse.wrapT = .clamp
        terrainMat.diffuse.mipFilter = .linear
        terrainMat.diffuse.maxAnisotropy = 8
        terrainMat.shaderModifiers = [.fragment: Self.terrainShader]
        let es = space.edgeScale
        terrainMat.setValue(SCNVector3(es.x, es.y, 0), forKey: "edgeScale")
        // 고해상 패치(S19 loadDetail): 붙기 전에는 UV 밖 자리라 쓰지 않는다
        terrainMat.setValue(SCNMaterialProperty(contents: UIColor.white), forKey: "detailTex")
        terrainMat.setValue(SCNVector4(2, 2, 3, 3), forKey: "detailRect")
        terrainMat.setValue(NSNumber(value: 0), forKey: "detailMix")
        terrain.geometry.firstMaterial = terrainMat
        terrainNode.geometry = terrain.geometry
        terrainNode.renderingOrder = Order.terrain

        // 리본은 깊이를 읽되(능선 뒤는 가려짐) 쓰지 않고 순서로 겹친다
        slopeNode.name = "slopes"
        liftNode.name = "lifts"
        stationNode.name = "stations"
        for n in levelNodes {
            n.renderingOrder = Order.slope
            slopeNode.addChildNode(n)
        }
        liftNode.renderingOrder = Order.lift
        highlightCasingNode.renderingOrder = Order.highlightCasing
        highlightNode.renderingOrder = Order.highlight
        dotNode.renderingOrder = Order.dot
        for k in [RouteSegment.Kind.run, .lift, .other] { routeMats[k] = [Self.flat(), Self.flat()] }

        // 승·하차장 점: 카메라를 보는 판, 지형에 가려진다(깊이 읽기)
        stationPlane.firstMaterial = stationMat
        for _ in stations {
            let n = SCNNode(geometry: stationPlane)
            n.renderingOrder = Order.station
            n.constraints = [SCNBillboardConstraint()]
            stationNode.addChildNode(n)
        }

        // 재생 점: 항상 카메라를 보는 판, 지형에 가려지지 않게 맨 위
        dotNode.geometry = SCNPlane(width: 32, height: 32)
        dotNode.geometry?.firstMaterial = dotMat
        dotMat.readsFromDepthBuffer = false
        dotNode.constraints = [SCNBillboardConstraint()]
        dotNode.isHidden = true

        for n in [terrainNode, slopeNode, liftNode, stationNode, routeNode, highlightCasingNode, highlightNode, dotNode] { scene.rootNode.addChildNode(n) }

        applyColors()
        buildRibbons()
        applyCamera(animated: false)
        applyPlayback()
    }

    // MARK: 모양

    func setDark(_ dark: Bool) {
        guard dark != self.dark else { return }
        self.dark = dark
        applyColors()
    }

    /// 슬로프 색 선, 리프트 점선·승하차장 점 보이기·숨기기. 눈 띠와 내 경로는 그대로
    func setLayers(_ layers: MapLayers) {
        slopeNode.isHidden = !layers.slopes
        liftNode.isHidden = !layers.lifts
        stationNode.isHidden = !layers.lifts
    }

    /// nil: 경로 전체를 진하게, 점 숨김. 값이 같으면 아무것도 하지 않는다.
    /// S19(추적 경로가 있으면): 재생 시각마다 추적 카메라를 한 걸음. 처음부터 다시 재생하면 추적을 다시 켠다
    func setPlayback(_ now: Date?, clock: CFTimeInterval = CACurrentMediaTime()) {
        guard now != playback else { return }
        if let now, let old = playback, now < old, let first = followPath.first, now <= first.t.addingTimeInterval(1) { followOn = true }
        let wasNil = playback == nil
        playback = now
        applyPlayback()
        guard isFollowing, let now, let dot else { return }
        let dt = wasNil || followClock == 0 ? Float(1.0 / 30) : Float(clock - followClock)
        followClock = clock
        let ahead = aheadPoint(at: now), back = Self.ahead(path: followPath, dist: followDist, at: now, by: -60)
        var c = Camera3D.follow(from: camera, dot: dot, ahead: ahead, back: back, dt: dt)
        // 슬라이더로 크게 건너뛰면(150m 넘게) 목표점만 바로 맞춘다(점이 화면 밖에 남지 않게)
        if let last = lastFollowDot, simd_distance(last, dot) > 150 { c.target = dot + (ahead - dot) * 0.35 }
        lastFollowDot = dot
        camera = clamp(c)
        applyCamera(animated: false)
        gestureEnded()   // 화면 1pt 길이가 15% 넘게 바뀌면 선 굵기를 다시 맞춘다
    }
    private var lastFollowDot: SIMD3<Float>?

    /// 추적을 멈춘다(손짓)
    func stopFollowing() { followOn = false }

    /// 재생 시각의 경로 위치에서 경로를 따라 followAhead m 앞 점. 남은 거리가 모자라면 도착점
    func aheadPoint(at now: Date) -> SIMD3<Float> {
        Self.ahead(path: followPath, dist: followDist, at: now, by: Camera3D.followAhead)
    }

    static func ahead(path: [(t: Date, p: SIMD3<Float>)], dist: [Float], at now: Date, by meters: Float) -> SIMD3<Float> {
        guard let last = path.last else { return .zero }
        let i = path.lastIndex { $0.t <= now } ?? 0
        var s = dist[i]
        if i + 1 < path.count {
            let span = path[i + 1].t.timeIntervalSince(path[i].t)
            if span > 0 { s += (dist[i + 1] - dist[i]) * Float(min(max(now.timeIntervalSince(path[i].t) / span, 0), 1)) }
        }
        let want = max(s + meters, 0)
        guard let j = dist.firstIndex(where: { $0 >= want }) else { return last.p }
        guard j > 0 else { return path[0].p }
        let f = (want - dist[j - 1]) / max(dist[j] - dist[j - 1], 0.001)
        return path[j - 1].p + (path[j].p - path[j - 1].p) * f
    }

    func setHighlight(_ run: RunDetector.Run?) {
        guard run != highlight else { return }
        highlight = run
        buildHighlight(lift: max(2, ribbonMPP), mpp: ribbonMPP)
    }

    // MARK: 카메라

    /// 날아 들어오기 시작 자리: 처음 시점에서 오른쪽으로 0.38rad(22도), pitch 62도, 거리 1.35배
    static let flyYaw: Float = 0.38, flyPitch: Float = 62 * .pi / 180, flyDistance: Float = 1.35

    /// 날아 들어오기의 진행 0…1(감속 곡선을 적용한 값). 시작 자리 → 처음 시점을 보간하고 제한을 적용한다. 1이면 처음 시점
    func setFlyIn(progress: Float) {
        let k = 1 - min(max(progress, 0), 1)
        if k == 0 {
            camera = start
        } else {
            var c = start
            c.yaw += Self.flyYaw * k
            c.pitch += (Self.flyPitch - start.pitch) * k
            c.distance *= 1 + (Self.flyDistance - 1) * k
            camera = clamp(c)
        }
        applyCamera(animated: false)
    }

    /// 화면 크기와 가려지는 높이(위 150, 아래 시트 높이 + 24)가 바뀔 때
    func setViewport(_ size: CGSize, topInset: CGFloat, bottomInset: CGFloat, animated: Bool) {
        guard size != viewport || topInset != self.topInset || bottomInset != self.bottomInset else { return }
        if size != viewport, size.height > 0 {
            // 화면 크기가 바뀌면 처음 시점을 다시 구한다. 카메라를 손대지 않았으면 새 처음 시점, 아니면 거리만 같은 비율로
            // (장면은 DayMapView 크기로 만들고 실제 SCNView 크기가 나중에 들어온다)
            let old = limit, untouched = camera == start
            limit = Camera3D.home(space, viewport: size)
            start = Self.fit(space, points: linePoints, viewport: size, top: topInset, bottom: size.height * 0.25 + 24, limit: limit, view3D: view3D)
            if untouched {
                camera = start
            } else {
                camera.distance *= limit.distance / max(old.distance, 1)
                camera = clamp(camera)
            }
        }
        viewport = size
        self.topInset = topInset
        self.bottomInset = bottomInset
        applyCamera(animated: animated)
    }

    /// 화면 너비만큼 끌면 180도, 높이만큼 끌면 90도
    func orbit(dx: CGFloat, dy: CGFloat) {
        camera.yaw -= Float(dx / max(viewport.width, 1)) * .pi
        camera.pitch += Float(dy / max(viewport.height, 1)) * .pi / 2
        update()
    }

    /// factor > 1: 확대(가까이)
    func zoom(by factor: CGFloat) {
        guard factor > 0 else { return }
        camera.distance /= Float(factor)
        update()
    }

    /// 손가락 방향으로 지도가 따라 움직인다
    func pan(dx: CGFloat, dy: CGFloat) {
        let mpp = camera.metersPerPoint(viewportHeight: viewport.height)
        let right = SIMD3(cos(camera.yaw), 0, -sin(camera.yaw))
        let forward = SIMD3(-sin(camera.yaw), 0, -cos(camera.yaw))   // 화면 위쪽 = 카메라에서 먼 쪽
        camera.target += -right * Float(dx) * mpp + forward * Float(dy) * mpp / max(sin(camera.pitch), 0.1)
        update()
    }

    /// 손짓이 끝남: 화면 1pt 길이가 15% 넘게 바뀌었으면 리본을 다시 만든다
    func gestureEnded() {
        let mpp = camera.metersPerPoint(viewportHeight: viewport.height)
        if ribbonMPP > 0, abs(mpp / ribbonMPP - 1) > 0.15 { buildRibbons() }
    }

    /// duration: 재생 끝에 추적 시점에서 돌아올 때는 길게
    func resetCamera(animated: Bool, duration: CFTimeInterval = 0.25) {
        followOn = true
        followClock = 0
        lastFollowDot = nil
        camera = start
        applyCamera(animated: animated, duration: duration)
        gestureEnded()
    }

    /// 목표점을 p로 (따라가기)
    func center(on p: SIMD3<Float>, animated: Bool) {
        camera.target = p
        camera = clamp(camera)
        applyCamera(animated: animated)
    }

    // MARK: 내부

    private func update() {
        camera = clamp(camera)
        applyCamera(animated: false)
    }

    /// S19(추적 경로가 있으면)는 추적 거리의 0.8배까지 가까이
    private func clamp(_ c: Camera3D) -> Camera3D {
        c.clamped(space, home: limit, minDistance: followPath.isEmpty ? nil : Camera3D.followDistance * 0.8)
    }

    /// 처음 시점 확인 기준: 시트 위 선(bottomEdge at 0.5)에서 보는 땅의 원형 가장자리 값. 시트 뒤는 원 밖이어도 된다
    static let startEdge: Float = 0.5
    /// 처음 pitch 42도(3D v5 카메라). 리조트 view3D.pitch가 있으면 그 값(30~60도)
    static let startPitch: Float = 42 * .pi / 180
    /// S19 진입 pitch 55도(수평 기준): 하강 전체를 높은 곳에서
    static let runPitch: Float = 55 * .pi / 180
    /// 안전 영역 위 여백: 위 가림(top) + 24pt
    static let startPadTop: CGFloat = 24

    /// 처음 시점: 슬로프·리프트 점 전부의 화면 상자가 안전 영역(좌우 16, 위 top + 24, 아래 H − bottom)의 폭이나 높이를 채우고 가운데에 오는 거리와 목표점.
    /// yaw·pitch는 고정(view3D 값 또는 0·42도). 거리 배율과 가운데 이동을 최대 8번 되풀이한 뒤 view3D.zoom을 곱한다
    private static func fit(_ space: Terrain3D, points: [SIMD3<Float>], viewport: CGSize,
                            top: CGFloat, bottom: CGFloat, limit: Camera3D, view3D: Resort.View3D?) -> Camera3D {
        let pitch = view3D?.pitch.map { Float(min(max($0, 30), 60)) * .pi / 180 } ?? startPitch
        let yaw = Float(view3D?.yaw ?? 0) * .pi / 180
        func clamp(_ c: Camera3D) -> Camera3D { var c = c; c.pitch = pitch; c.yaw = yaw; return c.clamped(space, home: limit) }
        var c = clamp(limit)
        guard !points.isEmpty, viewport.height > 0 else { return c }
        let area = CGRect(x: 16, y: top + startPadTop, width: max(1, viewport.width - 32),
                          height: max(1, viewport.height - bottom - top - startPadTop))
        func box(_ c: Camera3D) -> CGRect {
            var lo = CGPoint(x: CGFloat.infinity, y: .infinity), hi = CGPoint(x: -CGFloat.infinity, y: -.infinity)
            for p in points {
                let s = c.screen(p, viewport: viewport, top: top, bottom: bottom)
                lo = CGPoint(x: min(lo.x, s.x), y: min(lo.y, s.y)); hi = CGPoint(x: max(hi.x, s.x), y: max(hi.y, s.y))
            }
            return CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
        }
        // 상자 가운데 − 영역 가운데(pt, 오른쪽·위가 +)
        func offset(_ c: Camera3D) -> SIMD2<Float> { let m = box(c); return SIMD2(Float(m.midX - area.midX), Float(area.midY - m.midY)) }
        // 목표점을 화면 m(pt)만큼 옮기기. 비탈 높이·원근 때문에 실제로 움직이는 양이 달라 축마다 지난번 비율(gain)로 나눈다
        var gain = SIMD2<Float>(1, 1)
        // 한 번: 거리 k배 후 가운데로. 남은 어긋남(pt)
        func step(_ k: Float) -> Float {
            c.distance *= k
            c = clamp(c)
            let d0 = offset(c), m = d0 / gain
            let mpp = c.metersPerPoint(viewportHeight: viewport.height)
            c.target += SIMD3(cos(yaw), 0, -sin(yaw)) * m.x * mpp + SIMD3(-sin(yaw), 0, -cos(yaw)) * m.y * mpp / max(sin(pitch), 0.1)
            c = clamp(c)
            let d1 = offset(c)
            for i in 0..<2 where abs(m[i]) > 0.5 { gain[i] = min(max((d0[i] - d1[i]) / m[i], 0.2), 5) }
            return simd_length(d1)
        }
        for _ in 0..<8 {
            let b = box(c), k = Float(max(b.width / area.width, b.height / area.height))
            if step(k) < 0.5, abs(k - 1) < 0.002 { break }
        }
        // 리조트별 배수: 맞춘 거리에 곱하고 다시 가운데로
        let zoom = Float(min(max(view3D?.zoom ?? 1, 0.4), 1.5))
        if zoom != 1 {
            var d = step(zoom)
            for _ in 0..<7 where d >= 0.5 { d = step(1) }
        }
        return c
    }

    /// 처음 시점(날아 들어오기가 끝난 자리)에서 화면 전체(시트 뒤 포함)에 보이는 땅의 격자 범위(행0, 열0, 행1, 열1).
    /// 7×9 점의 광선이 닿는 곳 + 2칸
    func detailWindow() -> SIMD4<Float>? {
        let t = space.terrain
        var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
        for i in 0...8 {
            for j in 0...6 {
                let pt = CGPoint(x: viewport.width * CGFloat(j) / 6, y: viewport.height * CGFloat(i) / 8)
                guard let g = start.ground(pt, viewport: viewport, top: topInset, bottom: bottomInset, space: space) else { continue }
                let c = space.coordinate(g), rc = SIMD2(Float((t.north - c.lat) / t.step), Float((c.lon - t.west) / t.step))
                lo = simd_min(lo, rc); hi = simd_max(hi, rc)
            }
        }
        guard lo.x < hi.x, lo.y < hi.y else { return nil }
        lo = simd_max(lo - 2, .zero); hi = simd_min(hi + 2, SIMD2(Float(t.rows - 1), Float(t.cols - 1)))
        guard lo.x < hi.x, lo.y < hi.y else { return nil }
        return SIMD4(lo.x, lo.y, hi.x, hi.y)
    }

    private var detailLoading = false

    /// S19: 처음 시점에 보이는 땅만 2048 질감으로 다시 그려(나무 모양·그림자) 지형 질감 위에 0.6초에 걸쳐 덮는다. 몇 초 걸려 메인 스레드 밖에서.
    /// 화면 크기가 정해진 뒤(onReady) 한 번만 부른다.
    /// ponytail: 캐시 없음(열 때마다 만든다), 화면을 닫아도 만들던 것은 끝까지 돈다(결과만 버림). 느리면 하강별 캐시·중간 취소
    func loadDetail() async {
        guard !detailLoading, let win = detailWindow() else { return }
        detailLoading = true
        let (space, map) = (space, map)
        let image = await Task.detached(priority: .utility) { space.groundTexture(map: map, mesh: space.mesh(), window: win, canopy: .load(resortId: map.resortId)).image }.value
        guard let image, !Task.isCancelled else { return }
        let t = space.terrain
        let p = SCNMaterialProperty(contents: image)
        p.mipFilter = .linear
        terrainMat.setValue(p, forKey: "detailTex")
        terrainMat.setValue(SCNVector4(win.y / Float(t.cols - 1), win.x / Float(t.rows - 1), win.w / Float(t.cols - 1), win.z / Float(t.rows - 1)), forKey: "detailRect")
        terrainMat.setValue(NSNumber(value: 1), forKey: "detailMix")
        let fade = CABasicAnimation(keyPath: "detailMix")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.6
        terrainMat.addAnimation(fade, forKey: "detailFade")
    }

    private func applyCamera(animated: Bool, duration: CFTimeInterval = 0.25) {
        let mpp = camera.metersPerPoint(viewportHeight: viewport.height)
        // 목표점을 시트 위 보이는 영역 가운데로: 카메라를 화면 세로 방향으로 평행 이동
        let visibleMid = topInset + max(80, viewport.height - topInset - bottomInset) / 2
        let shift = Float(viewport.height / 2 - visibleMid) * mpp
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? duration : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cameraNode.simdPosition = camera.position
        cameraNode.simdLook(at: camera.target, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        cameraNode.simdPosition -= cameraNode.simdWorldUp * shift
        // 먼 산은 뒤 하늘빛으로 옅어진다(셰이더 안개)
        terrainMat.setValue(NSNumber(value: camera.distance + space.radius * 0.5), forKey: "fogStart")
        terrainMat.setValue(NSNumber(value: camera.distance + space.radius * 5), forKey: "fogEnd")
        dotNode.simdScale = SIMD3(repeating: mpp)
        for n in stationNode.childNodes { n.simdScale = SIMD3(repeating: mpp) }
        SCNTransaction.commit()
    }

    private static func line(_ l: [[Double]]) -> [(lat: Double, lon: Double)] { l.map { (lat: $0[0], lon: $0[1]) } }

    /// 리본 굵기(m) = 2D pt 값 × 화면 1pt 길이
    private func buildRibbons() {
        let mpp = camera.metersPerPoint(viewportHeight: viewport.height)
        ribbonMPP = mpp
        let lift = max(2, mpp)
        let line = Self.line

        // 슬로프 색 선: 난이도 단계마다 지오메트리 하나
        let byLevel = Dictionary(grouping: map.slopes) { SlopeStyle.level($0.difficulty) }
        for (i, level) in SlopeStyle.Level.allCases.enumerated() {
            let ribbons = (byLevel[level] ?? []).flatMap(\.lines).map { space.ribbon(line($0), width: 1.5 * mpp, lift: lift) }
            levelNodes[i].geometry = Terrain3D.Ribbon.geometry(ribbons)
            levelNodes[i].geometry?.firstMaterial = levelMats[i]
        }
        let lifts = map.lifts.map { space.ribbon(line($0.line), width: 1.5 * mpp, lift: lift, dash: (4 * mpp, 4 * mpp)) }
        liftNode.geometry = Terrain3D.Ribbon.geometry(lifts)
        liftNode.geometry?.firstMaterial = liftMat
        // 승·하차장 점: 판 아래 절반이 비탈에 묻히지 않게 반지름만큼 더 띄운다
        for (n, p) in zip(stationNode.childNodes, stations) { n.simdPosition = space.point(lat: p[0], lon: p[1], lift: lift + 4 * mpp) }

        // 경로: 조각마다 옅은 전체(알파 0.3배)와 진한 앞부분 두 겹. 꺾인 곳은 둥글게(Chaikin 2회)
        routeNode.childNodes.forEach { $0.removeFromParentNode() }
        segments = route.map { seg in
            let (w, dash): (Float, (on: Float, off: Float)?) = switch seg.kind {
            case .run: (4.5, nil)
            case .lift: (2.5, (5 * mpp, 4 * mpp))
            case .other: (2, nil)
            }
            let pts = seg.points.map { (lat: $0.lat, lon: $0.lon) }
            func ribbon(_ width: Float) -> Terrain3D.Ribbon { space.ribbon(pts, width: width * mpp, lift: lift, dash: dash, smooth: 2) }
            let r = ribbon(w)
            // 하강 아래 12pt 번짐(같은 색 22%)
            if seg.kind == .run, let g = ribbon(12).geometry() {
                g.firstMaterial = glowMat
                let glow = SCNNode(geometry: g)
                glow.renderingOrder = Order.glow
                routeNode.addChildNode(glow)
            }
            // 하강·탄 리프트 아래 양쪽 1.25pt 넓은 테두리(숲 위에서도 보이게). 재생 중에도 전체
            if seg.kind != .other, let g = ribbon(w + 2.5).geometry() {
                let casing = SCNNode(geometry: g)
                g.firstMaterial = casingMat
                casing.renderingOrder = Order.casing
                routeNode.addChildNode(casing)
            }
            let solid = SCNNode(), faded = SCNNode()
            for (i, n) in [solid, faded].enumerated() {
                n.geometry = r.geometry()
                n.geometry?.firstMaterial = routeMats[seg.kind]?[i]
                n.renderingOrder = i == 0 ? Order.solid : Order.faded
                n.isHidden = r.indices.isEmpty
                routeNode.addChildNode(n)
            }
            return (seg, r, solid, faded)
        }
        buildHighlight(lift: lift, mpp: mpp)
        // 리본을 새로 만들었으니 진한 앞부분 범위를 다시 맞춘다
        applyPlayback()
    }

    /// 하강 강조: 그 하강 시간 구간의 리본을 7pt(테두리 9.5pt)로 덧그림
    private func buildHighlight(lift: Float, mpp: Float) {
        guard let h = highlight else { highlightNode.geometry = nil; highlightCasingNode.geometry = nil; return }
        let lines = route.filter { $0.kind == .run }.map { seg in
            seg.points.filter { $0.t >= h.start && $0.t <= h.end }.map { (lat: $0.lat, lon: $0.lon) }
        }
        highlightNode.geometry = Terrain3D.Ribbon.geometry(lines.map { space.ribbon($0, width: 7 * mpp, lift: lift, smooth: 2) })
        highlightNode.geometry?.firstMaterial = highlightMat
        highlightCasingNode.geometry = Terrain3D.Ribbon.geometry(lines.map { space.ribbon($0, width: 9.5 * mpp, lift: lift, smooth: 2) })
        highlightCasingNode.geometry?.firstMaterial = casingMat
    }

    /// 진한 앞부분은 그릴 삼각형 수(primitiveRange)만 바꾼다. 재생 점 위치도 여기서
    private func applyPlayback() {
        for s in segments {
            let total = s.ribbon.indices.count / 3
            guard total > 0 else { continue }
            var n = total
            if let now = playback {
                // ponytail: 마지막으로 지난 입력 점까지만 진하게(점 사이 보간 없음). 거슬리면 걸친 조각만 다시 만든다
                if let first = s.seg.points.first, now < first.t { n = 0 }
                else if let i = s.seg.points.lastIndex(where: { $0.t <= now }), i < s.ribbon.cuts.count { n = s.ribbon.cuts[i] }
            }
            s.faded.isHidden = playback == nil
            s.solid.isHidden = n == 0
            let range = NSRange(location: 0, length: n)
            if let el = s.solid.geometry?.elements.first, el.primitiveRange != range { el.primitiveRange = range }
        }
        if let now = playback, let p = route.lazy.compactMap({ $0.position(at: now) }).first {
            let q = space.point(lat: p.lat, lon: p.lon, lift: max(2, ribbonMPP))
            dot = q
            dotNode.simdPosition = q
            dotNode.isHidden = false
        } else {
            dot = nil
            dotNode.isHidden = true
        }
    }

    private func applyColors() {
        let c = DayMapDrawing.Palette(dark: dark)
        let w = Terrain3D.WinterPalette(dark: dark)
        func vec(_ v: SIMD3<Float>) -> SCNVector3 { let l = Terrain3D.linear(v); return SCNVector3(l.x, l.y, l.z) }
        // 3D v5: 하늘 그라데이션 배경. 지형 가장자리·안개는 화면 같은 높이의 배경색으로 녹는다. 질감 × 모드 색(셰이더)
        scene.background.contents = Self.skyImage(w)
        for (k, v) in [("skyTop", w.skyTop), ("skyMid", w.skyMid), ("skyHaze", w.haze), ("skyGround", w.ground)] { terrainMat.setValue(vec(v), forKey: k) }
        terrainMat.setValue(SCNVector3(w.tintLow.x, w.tintLow.y, w.tintLow.z), forKey: "tintLow")
        terrainMat.setValue(SCNVector3(w.tintHigh.x, w.tintHigh.y, w.tintHigh.z), forKey: "tintHigh")
        let lift = Self.color(dark ? 0xC4D3DA : 0x34474E)
        liftMat.diffuse.contents = lift
        stationMat.diffuse.contents = Self.stationImage(fill: lift, border: Self.color(dark ? 0x0B161B : 0xFFFFFF))
        casingMat.diffuse.contents = c.dot
        highlightMat.diffuse.contents = c.text
        // 번짐 22%. 더하기 섞기는 투명도를 보지 않아 색에 미리 곱한다
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, al: CGFloat = 0
        c.fill.getRed(&r, green: &g, blue: &b, alpha: &al)
        glowMat.diffuse.contents = dark ? UIColor(red: r * 0.22, green: g * 0.22, blue: b * 0.22, alpha: 1) : c.fill
        glowMat.transparency = dark ? 1 : 0.22
        glowMat.blendMode = dark ? .add : .alpha
        for (k, mats) in routeMats {
            let (color, a): (UIColor, CGFloat) = switch k {
            case .run: (c.fill, 1)
            case .lift: (c.text, 1)
            case .other: (c.fill, 0.5)
            }
            mats[0].diffuse.contents = color
            mats[0].transparency = a
            mats[1].diffuse.contents = color
            mats[1].transparency = a * 0.3
        }
        dotMat.diffuse.contents = Self.dotImage(c, dark: dark)
    }

    /// 질감(선형) × 모드 색(밝기에 따라 tintLow → tintHigh). 화면 높이 t(위 0 … 아래 1)의 배경색 sky(t)를 skyImage와 같은 선형 보간으로 구해
    /// 원형 가장자리(edgeScale, Terrain3D.edgeScale)와 거리 안개(fogStart → fogEnd)만큼 그 색으로 섞는다. 가장자리가 하늘·땅 안개에 이음매 없이 녹는다
    private static let terrainShader: String = {
        let s = Terrain3D.skyStops
        return """
        #pragma arguments
        float3 skyTop;
        float3 skyMid;
        float3 skyHaze;
        float3 skyGround;
        float3 tintLow;
        float3 tintHigh;
        float3 edgeScale;
        float fogStart;
        float fogEnd;
        float4 detailRect;
        float detailMix;
        texture2d<float> detailTex;
        #pragma body
        float3 c = _surface.diffuse.rgb;
        // 고해상 패치(detailRect: UV u0, v0, u1, v1) 안이면 그 질감. 패치 가장자리 6%에서 섞는다
        float2 du = (_surface.diffuseTexcoord - detailRect.xy) / (detailRect.zw - detailRect.xy);
        float din = min(min(du.x, 1.0 - du.x), min(du.y, 1.0 - du.y));
        if (din > 0.0) {
            constexpr sampler ds(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(8));
            c = mix(c, detailTex.sample(ds, du).rgb, smoothstep(0.0, 0.06, din) * detailMix);
        }
        float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
        c *= mix(tintLow, tintHigh, smoothstep(0.03, 0.8, lum));
        float4 clip = scn_frame.projectionTransform * float4(_surface.position, 1.0);
        float t = clamp(0.5 - 0.5 * clip.y / clip.w, 0.0, 1.0);
        float3 sky = t < \(s[1]) ? mix(skyTop, skyMid, t / \(s[1]))
                   : t < \(s[2]) ? mix(skyMid, skyHaze, (t - \(s[1])) / \(s[2] - s[1]))
                   : mix(skyHaze, skyGround, clamp((t - \(s[2])) / \(s[3] - s[2]), 0.0, 1.0));
        float2 q = (_surface.diffuseTexcoord - 0.5) * edgeScale.xy;
        float e = smoothstep(0.0, 1.0, clamp((1.0 - 2.0 * length(q)) / 0.2, 0.0, 1.0));
        float fog = clamp((length(_surface.position) - fogStart) / max(fogEnd - fogStart, 1.0), 0.0, 1.0);
        _output.color = float4(mix(sky, c, e * (1.0 - fog)), 1.0);
        """
    }()

    /// 조명을 받지 않는 양면 단색 리본 재질
    private static func flat() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        return m
    }

    private static func color(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// 하늘: Terrain3D.skyStops 자리에 맨 위 → 하늘 → 지평 안개 → 땅 안개(끝까지). 선형 색 공간에서 보간(셰이더와 같게)
    private static func skyImage(_ w: Terrain3D.WinterPalette) -> UIImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.preferredRange = .standard
        let space = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let colors = [w.skyTop, w.skyMid, w.haze, w.ground, w.ground].map { v in
            let l = Terrain3D.linear(v)
            return CGColor(colorSpace: space, components: [CGFloat(l.x), CGFloat(l.y), CGFloat(l.z), 1])!
        }
        let stops = (Terrain3D.skyStops + [1]).map { CGFloat($0) }
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 512), format: f).image { ctx in
            let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops)!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 512), options: [])
        }
    }

    /// 승·하차장 점: 6pt 원 + 테두리 1pt (판 8pt)
    private static func stationImage(fill: UIColor, border: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(border.cgColor)
            cg.fillEllipse(in: CGRect(x: 0, y: 0, width: 8, height: 8))
            cg.setFillColor(fill.cgColor)
            cg.fillEllipse(in: CGRect(x: 1, y: 1, width: 6, height: 6))
        }
    }

    /// 2D와 같은 재생 점: 옅은 원 32pt + 흰 원 16pt + 테두리 3pt
    private static func dotImage(_ c: DayMapDrawing.Palette, dark: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(c.fill.withAlphaComponent(dark ? 0.25 : 0.2).cgColor)
            cg.fillEllipse(in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let dot = CGRect(x: 8, y: 8, width: 16, height: 16)
            cg.setFillColor(c.dot.cgColor)
            cg.fillEllipse(in: dot)
            cg.setStrokeColor(c.text.cgColor)
            cg.setLineWidth(3)
            cg.strokeEllipse(in: dot)
        }
    }
}
