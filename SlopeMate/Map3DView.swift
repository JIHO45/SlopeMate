import SceneKit
import SwiftUI

/// S6 3D 보기 (R50, K; 05-design 4장 "화면용 3D 보기"). SCNView를 감싸고 손짓을 장면 카메라 함수로 넘긴다.
/// 한 손가락 끌기 = 돌리기·기울이기, 두 손가락 벌리기 = 확대, 두 손가락 끌기 = 이동, 두 번 누르기 = 처음 시점,
/// 한 번 누르기 = 슬로프 이름(두 번 누르기가 실패한 뒤). 관성 없음.
struct Map3DView: UIViewRepresentable {
    let scene: Map3DScene
    var now: Date?
    var highlight: RunDetector.Run?
    var dark: Bool
    /// 시트 높이 + 24
    var bottomInset: CGFloat
    var reduceMotion: Bool
    /// 슬로프 색 선·리프트 보이기
    var layers = MapLayers()
    /// 첫 표시에 날아 들어올지(DayMapView가 동작 줄이기까지 판단해 넘김)
    var flyIn = false
    /// 미리 그리기가 끝남. DayMapView가 이때 겹쳐 바꾼다
    var onReady: () -> Void = {}
    /// 한 번 누르기 결과. 슬로프가 없거나 layers.slopes가 꺼져 있으면 nil. 지도 손짓이 시작될 때도 nil로 부른다
    var onTap: (SlopePick.Hit?) -> Void = { _ in }

    /// 위에 가려지는 높이(하늘이 들어오게 150)
    static let topInset: CGFloat = 150
    /// 날아 들어오기 시간(초)
    static let flyDuration: Double = 1.1
    /// 이 폭 안에서 시작한 한 손가락 끌기는 받지 않는다(왼쪽 가장자리 뒤로 가기)
    static let backEdge: CGFloat = 24

    func makeCoordinator() -> Coordinator { Coordinator(scene) }

    func makeUIView(context: Context) -> SCNView {
        let v = LayoutView(frame: .zero, options: nil)
        v.scene = scene.scene
        v.pointOfView = scene.cameraNode
        v.allowsCameraControl = false
        v.rendersContinuously = false // 장면이 바뀔 때만 그린다
        v.isPlaying = false
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = .clear
        let c = context.coordinator
        c.view = v
        v.onLayout = { [weak c] in c?.layout() }

        let orbit = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.orbit(_:)))
        orbit.maximumNumberOfTouches = 1
        orbit.delegate = c
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.delegate = c
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = c
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.home(_:)))
        tap.numberOfTapsRequired = 2
        let pick = UITapGestureRecognizer(target: c, action: #selector(Coordinator.pick(_:)))
        pick.require(toFail: tap)
        for g in [orbit, pan, pinch, tap, pick] { v.addGestureRecognizer(g) }
        scene.setLayers(layers)
        c.layers = layers
        c.flyIn = flyIn && !reduceMotion
        c.onReady = onReady
        // 셰이더를 미리 컴파일해 첫 화면이 끊기지 않게 한 뒤 알린다
        v.prepare([scene.scene]) { @Sendable [weak c] _ in
            Task { @MainActor [c] in c?.ready() }
        }
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        let c = context.coordinator
        c.scene = scene
        c.reduceMotion = reduceMotion
        c.flyIn = flyIn && !reduceMotion
        c.onReady = onReady
        c.onTap = onTap
        if c.layers != layers {
            c.layers = layers
            scene.setLayers(layers)
        }
        scene.setDark(dark)
        scene.setHighlight(highlight)
        if c.bottomInset != bottomInset {
            c.bottomInset = bottomInset
            c.layout(animated: !reduceMotion)
        }
        scene.setPlayback(now)
        if now != nil, now != c.now, !scene.isFollowing { c.follow() }
        c.now = now
    }

    final class LayoutView: SCNView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var scene: Map3DScene
        weak var view: SCNView?
        var bottomInset: CGFloat = 0
        var reduceMotion = false
        var now: Date?
        var layers = MapLayers()
        var flyIn = false
        var onReady: () -> Void = {}
        var onTap: (SlopePick.Hit?) -> Void = { _ in }
        private var size: CGSize = .zero
        private var flight: CADisplayLink?
        private var flightStart: CFTimeInterval = 0

        init(_ scene: Map3DScene) { self.scene = scene }

        /// 화면 크기가 바뀌었을 때(처음 포함)
        func layout() {
            guard let v = view, v.bounds.size != .zero, v.bounds.size != size else { return }
            size = v.bounds.size
            layout(animated: false)
        }

        func layout(animated: Bool) {
            guard size != .zero else { return }
            scene.setViewport(size, topInset: Map3DView.topInset, bottomInset: bottomInset, animated: animated)
        }

        /// 재생 점이 시트 위 보이는 영역(안쪽 16pt) 밖이면 목표점을 점으로 (2D follow와 같은 규칙)
        func follow() {
            guard let v = view, size != .zero, let dot = scene.dot else { return }
            let p = v.projectPoint(SCNVector3(dot))
            let visible = CGRect(x: 16, y: Map3DView.topInset, width: size.width - 32,
                                 height: max(80, size.height - Map3DView.topInset - bottomInset))
            // z > 1이면 카메라 뒤
            guard p.z > 1 || !visible.insetBy(dx: 16, dy: 16).contains(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))) else { return }
            // 말풍선은 화면 좌표에 고정: 중심을 옮기면 닫는다(2D와 같다). updateUIView 안이라 다음 차례에
            let onTap = onTap
            DispatchQueue.main.async { onTap(nil) }
            scene.center(on: dot, animated: !reduceMotion)
        }

        /// 미리 그리기 끝: 날아 들어오기를 시작 자리에 두고 알린 뒤 1.1초 동안 처음 시점으로.
        /// rendersContinuously가 꺼져 있어도 카메라 노드가 바뀌면 SCNView가 다시 그린다(손짓과 같은 방식)
        func ready() {
            if flyIn {
                scene.setFlyIn(progress: 0)
                flightStart = CACurrentMediaTime()
                let link = CADisplayLink(target: self, selector: #selector(step(_:)))
                link.add(to: .main, forMode: .common)
                flight = link
            }
            onReady()
        }

        @objc func step(_ link: CADisplayLink) {
            let t = min(1, (CACurrentMediaTime() - flightStart) / Map3DView.flyDuration)
            scene.setFlyIn(progress: Float(1 - pow(1 - t, 3)))
            if t >= 1 { stopFlight() }
        }

        /// 손을 대면 그 자리에서 멈춘다
        private func stopFlight() {
            flight?.invalidate()
            flight = nil
        }

        /// 손짓 시작: 날아 들어오기를 멈추고 말풍선을 닫는다
        private func began(_ g: UIGestureRecognizer) {
            guard g.state == .began else { return }
            stopFlight()
            scene.stopFollowing()
            onTap(nil)
        }

        /// 한 번 누르기: 누른 점에서 22pt 안의 가장 가까운 슬로프. 카메라 뒤 점은 건너뛴다
        @objc func pick(_ g: UITapGestureRecognizer) {
            stopFlight()
            guard layers.slopes, let v = view else { onTap(nil); return }
            let space = scene.space
            onTap(SlopePick.nearest(to: g.location(in: v), in: scene.map) { p in
                let q = v.projectPoint(SCNVector3(space.point(lat: p[0], lon: p[1])))
                return q.z >= 1 || q.z < 0 ? nil : CGPoint(x: CGFloat(q.x), y: CGFloat(q.y))
            })
        }

        @objc func orbit(_ g: UIPanGestureRecognizer) {
            began(g)
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            scene.orbit(dx: t.x, dy: t.y)
            if g.state == .ended || g.state == .cancelled { scene.gestureEnded() }
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            began(g)
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            scene.pan(dx: t.x, dy: t.y)
            if g.state == .ended || g.state == .cancelled { scene.gestureEnded() }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            began(g)
            if g.scale > 0 { scene.zoom(by: g.scale) }
            g.scale = 1
            if g.state == .ended || g.state == .cancelled { scene.gestureEnded() }
        }

        @objc func home(_ g: UITapGestureRecognizer) {
            stopFlight()
            onTap(nil)
            scene.resetCamera(animated: !reduceMotion)
        }

        /// 한 손가락 끌기는 터치가 시작한 자리로 거른다(끌기가 시작될 때의 위치는 이미 움직인 뒤)
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, pan.maximumNumberOfTouches == 1 else { return true }
            return touch.location(in: pan.view).x >= Map3DView.backEdge
        }

        /// 두 손가락 확대와 이동은 같이
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let two: (UIGestureRecognizer) -> Bool = { $0 is UIPinchGestureRecognizer || ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2 }
            return two(g) && two(other)
        }
    }
}
