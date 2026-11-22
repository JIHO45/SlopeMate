import SceneKit
import SwiftUI

/// 리조트 화면 지도 (R58, B). S6(DayMapView)의 2D 지도·확대/이동·슬로프 말풍선·지도 표시 버튼과 3D 보기만 옮겼다.
/// 경로·재생·이용권 잠금·내 위치 없음. 2D/3D 고르기와 시트는 부르는 화면(ResortView)이 맡는다.
struct ResortMapView: View {
    let map: SlopeMap
    /// 부르는 화면의 2D/3D 세그먼트. 켜지면 처음 한 번 3D 장면을 만든다(그동안 2D). 고도 파일이 없으면 false로 되돌린다
    @Binding var is3D: Bool
    /// 시트 높이(pt). 2D 가운데, 3D 아래 가림(+24), 출처 표시 자리
    let sheetHeight: CGFloat

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var size: CGSize = .zero
    // 확대·이동
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    /// 2D 바탕 숲 질감. 준비되기 전에는 음영 바탕
    @State private var ground: CGImage?
    // 3D: 장면은 처음 켤 때 만들고 화면이 열려 있는 동안 둔다(DayMapView와 같은 흐름)
    @State private var scene3D: Map3DScene?
    @State private var preparing3D = false
    @State private var ready3D = false
    @State private var flownIn = false
    // 지도 표시 메뉴: 슬로프를 보려고 여는 화면이라 S6와 따로 기억하고 2D·3D 모두 기본 켬
    @AppStorage("resortMapShowSlopes") private var showSlopes = true
    @AppStorage("resortMapShowSlopes3D") private var showSlopes3D = true
    @AppStorage("resortMapShowLifts") private var showLifts = true
    @AppStorage("resortMapShowLifts3D") private var showLifts3D = true
    @State private var picked: SlopePick.Hit?
    @State private var balloonSize: CGSize = .zero

    private var dark: Bool { scheme == .dark }
    /// 슬로프 이름 말풍선은 이름 표시가 켜진 리조트만(R9)
    private var names: Bool { SlopeNames.isShown(map.resortId) }
    private var layers3D: MapLayers { MapLayers(slopes: showSlopes3D, lifts: showLifts3D) }
    private var drawing: DayMapDrawing {
        DayMapDrawing(map: map, route: [], dark: dark, terrain: Terrain.layer(map, dark: dark)?.with(ground: ground),
                      layers: MapLayers(slopes: showSlopes, lifts: showLifts))
    }

    var body: some View {
        ZStack {
            if !(is3D && ready3D) { canvas.transition(.opacity) }
            if is3D, let scene3D {
                Map3DView(scene: scene3D, dark: dark, bottomInset: sheetHeight + 24, reduceMotion: reduceMotion,
                          layers: layers3D, flyIn: !flownIn && !reduceMotion,
                          onReady: { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { ready3D = true } },
                          onTap: { picked = names && showSlopes3D ? $0 : nil })
                    .ignoresSafeArea()
                    .opacity(ready3D ? 1 : 0)
                    .accessibilityElement()
                    .accessibilityLabel("\(Resort.name(map.resortId)) 3D 지형 지도")
                    .accessibilityHidden(!ready3D)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0; prepare3D() }
        .overlay { balloon }
        .overlay { if is3D && !ready3D { ProgressView().accessibilityLabel("3D 준비 중") } }
        .overlay(alignment: .topTrailing) {
            MapLayersButton(slopes: is3D ? $showSlopes3D : $showSlopes, lifts: is3D ? $showLifts3D : $showLifts)
                .padding(.top, 8).padding(.trailing, 16)
        }
        .overlay(alignment: .bottomTrailing) {
            Text(drawing.terrain == nil ? "© OpenStreetMap" : is3D ? "© OpenStreetMap · Copernicus DEM · Meta·WRI" : "© OpenStreetMap · Copernicus DEM").font(.caption).foregroundStyle(Color.secondaryText)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge) // 출처 표시가 지도를 가리지 않게
                .padding(.trailing, 16).padding(.bottom, sheetHeight + 8)
                .ignoresSafeArea()
        }
        .task { ground = await Terrain.ground(map) }
        .onChange(of: is3D) {
            picked = nil
            if is3D { return prepare3D() }
            if ready3D { flownIn = true }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { ready3D = false }
        }
        // 말풍선은 화면 좌표에 고정: 지도가 움직이면(손짓·시트 높이) 닫는다. 슬로프를 끄면 닫는다
        .onChange(of: [zoom, pinch, pan.width, pan.height, drag.width, drag.height, sheetHeight]) { picked = nil }
        .onChange(of: showSlopes) { if !showSlopes { picked = nil } }
        .onChange(of: showSlopes3D) { if !showSlopes3D { picked = nil } }
    }

    /// 2D 지도 층. 한 번 누르기 = 슬로프 이름(끌기는 10pt 움직여야 시작해 겹치지 않는다)
    private var canvas: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let fit = fitRect(size)
                let d = drawing, t = transform(fit)
                ctx.withCGContext { cg in d.draw(cg, size: size, MapProjection(map, rect: fit), transform: t, now: nil) }
            }
            .gesture(MagnifyGesture()
                .updating($pinch) { v, s, _ in s = v.magnification }
                .onEnded { zoom = min(max(zoom * $0.magnification, 1), 8) }
                .simultaneously(with: DragGesture()
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onEnded { pan.width += $0.translation.width; pan.height += $0.translation.height }))
            .simultaneousGesture(SpatialTapGesture().onEnded { pick($0.location, in: geo.size) })
        }
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel("\(Resort.name(map.resortId)) 전체 슬로프 지도")
    }

    /// 누른 자리 22pt 안의 가장 가까운 슬로프. 없거나 슬로프를 꺼 두었거나 이름 표시가 꺼진 리조트면 닫는다
    private func pick(_ p: CGPoint, in size: CGSize) {
        guard showSlopes, names else { picked = nil; return }
        let fit = fitRect(size), proj = MapProjection(map, rect: fit), t = transform(fit)
        picked = SlopePick.nearest(to: p, in: map) { proj.point($0[0], $0[1]).applying(t) }
    }

    /// 말풍선: 누른 선 위 12pt, 좌우 16pt 안 (DayMapView와 같다)
    private var balloon: some View {
        GeometryReader { geo in
            if let picked {
                let w = balloonSize.width, h = balloonSize.height
                SlopeBalloon(hit: picked)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { balloonSize = $0 }
                    .position(x: min(max(picked.anchor.x, 16 + w / 2), geo.size.width - 16 - w / 2),
                              y: picked.anchor.y - 12 - h / 2)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// 3D가 켜졌고 장면이 없으면 지형 메시를 메인 스레드 밖에서 만들고(그동안 2D), 장면은 MainActor에서. 처음 3D로 열 때는 크기를 잰 뒤
    private func prepare3D() {
        guard is3D, scene3D == nil, !preparing3D, size != .zero else { return }
        guard let terrain = drawing.terrain?.terrain else { is3D = false; return }
        preparing3D = true
        let map = map, dark = dark, size = size
        Task {
            let (space, prepared) = await Task.detached(priority: .userInitiated) {
                let space = Terrain3D(terrain: terrain, map: map)
                return (space, Map3DTerrain(space: space, map: map))
            }.value
            scene3D = Map3DScene(space: space, terrain: prepared, map: map, route: [], dark: dark, viewport: size,
                                 view3D: Resort.all.first { $0.id == map.resortId }?.view3D)
            preparing3D = false
        }
    }

    private func fitRect(_ size: CGSize) -> CGRect { DayMapView.fitRect(size, sheetHeight: sheetHeight) }

    /// 영역 가운데를 기준으로 확대하고 이동
    private func transform(_ fit: CGRect) -> CGAffineTransform {
        let s = zoom * pinch
        return CGAffineTransform(translationX: -fit.midX, y: -fit.midY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: fit.midX + pan.width + drag.width, y: fit.midY + pan.height + drag.height))
    }
}

/// 홈 카드 ①의 3D 그림 (R58). 리조트 전체 처음 시점을 318×240pt로 한 장 찍는다. 늘 밝게(카드 위 유리 캡션과 맞춤).
/// 지형·장면은 ResortMapView 3D와 같은 방법. 아래 84pt(25% + 24)는 캡션 자리로 비운다
@MainActor enum Resort3DSnapshot {
    static let size = CGSize(width: 318, height: 240)
    private static var memory: [String: UIImage] = [:]
    /// 만드는 중인 리조트: 카드가 다시 나타나도 두 번 만들지 않는다
    private static var making: [String: Task<UIImage?, Never>] = [:]

    /// 고도·지도 파일이 없으면 nil
    static func image(resortId: String) async -> UIImage? {
        if let hit = memory[resortId] { return hit }
        if let task = making[resortId] { return await task.value }
        let task = Task { await make(resortId) }
        making[resortId] = task
        let image = await task.value
        making[resortId] = nil
        memory[resortId] = image
        return image
    }

    // ponytail: 디스크 캐시는 빌드 번호(CFBundleVersion)로만 무효화한다. 같은 빌드에서 지형·색·view3D를 바꿔도 다시 만들지 않고,
    // 예전 빌드 파일은 지우지 않는다(Caches라 OS가 정리). 개발 중 바뀐 3D를 보려면 앱을 지우거나 빌드 번호를 올린다
    private static func file(_ id: String) -> URL {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("resort3d-v2-\(id)-\(build).jpg")   // v2: 리프트 없는 그림(예전 파일은 쓰지 않음)
    }

    private static func make(_ id: String) async -> UIImage? {
        let scale: CGFloat = 3
        let url = file(id)
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data, scale: scale) { return image }
        guard let map = SlopeMap.cached(resortId: id) else { return nil }
        guard let built = await Task.detached(priority: .utility, operation: { () -> (Terrain3D, Map3DTerrain)? in
            guard let terrain = Terrain.load(resortId: id) else { return nil }
            let space = Terrain3D(terrain: terrain, map: map)
            return (space, Map3DTerrain(space: space, map: map))
        }).value else { return nil }
        let (space, prepared) = built
        // 다른 크기로 만든 뒤 setViewport로 바꿔야 처음 시점을 위 가림 0으로 다시 맞춘다(같은 크기면 다시 구하지 않는다)
        let scene = Map3DScene(space: space, terrain: prepared, map: map, route: [], dark: false,
                               viewport: CGSize(width: size.width, height: size.height * 2),
                               view3D: Resort.all.first { $0.id == id }?.view3D)
        scene.setViewport(size, topInset: 0, bottomInset: size.height * 0.25 + 24, animated: false)
        // 홈 카드는 맛보기라 슬로프 선만: 리프트 선·양 끝 점이 슬로프보다 먼저 보여 끈다(2026-11-22 사용자). 리조트 화면 3D는 그대로
        scene.setLayers(MapLayers(slopes: true, lifts: false))
        // 첫 렌더는 Metal 셰이더 컴파일로 1초 넘게 걸려 메인에서 하면 홈이 멈춘다(테스트 호스트도 멈춤). 화면에 붙지 않은 장면이라
        // 렌더러는 메인 밖에서 돌리고, 장면은 이 함수 밖에서 아무도 건드리지 않는다
        let job = SnapshotJob(scene: scene.scene, camera: scene.cameraNode,
                              pixels: CGSize(width: size.width * scale, height: size.height * scale))
        guard let cg = await Task.detached(priority: .utility, operation: { job.render() }).value else { return nil }
        let image = UIImage(cgImage: cg, scale: scale, orientation: .up)
        try? image.jpegData(compressionQuality: 0.85)?.write(to: url, options: .atomic)
        return image
    }
}

/// 스냅샷 한 장 렌더: 만든 장면을 넘겨받아 메인 밖에서 그린다(장면은 이 작업만 쓰므로 unchecked)
private nonisolated struct SnapshotJob: @unchecked Sendable {
    let scene: SCNScene
    let camera: SCNNode
    let pixels: CGSize

    func render() -> CGImage? {
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        return renderer.snapshot(atTime: 0, with: pixels, antialiasingMode: .multisampling4X).cgImage
    }
}

/// 정지 2D 지도(손짓·말풍선 없음). S1 미리보기 등 작은 자리용. 주어진 크기를 채운다
struct ResortMapThumbnail: View {
    let map: SlopeMap
    @Environment(\.colorScheme) private var scheme
    @State private var ground: CGImage?

    var body: some View {
        let d = DayMapDrawing(map: map, route: [], dark: scheme == .dark,
                              terrain: Terrain.layer(map, dark: scheme == .dark)?.with(ground: ground))
        Canvas { ctx, size in
            ctx.withCGContext { cg in d.draw(cg, size: size, MapProjection(map, rect: CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12)), now: nil) }
        }
        .task { ground = await Terrain.ground(map) }
        .accessibilityElement()
        .accessibilityLabel("\(Resort.name(map.resortId)) 슬로프 지도")
    }
}

#Preview {
    NavigationStack {
        if let map = SlopeMap.load(resortId: "high1") {
            ResortMapView(map: map, is3D: .constant(false), sheetHeight: 220)
        }
    }
}
