import Testing
import UIKit
@testable import SlopeMate

/// 지도 표시 설정(layers)과 공유 동영상 v2 (R50, K)
@MainActor struct DayMapLayersTests {
    func pixels(_ size: CGSize, _ draw: (CGContext) -> Void) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }
        return img.cgImage!.dataProvider!.data! as Data
    }

    /// 3D 난이도 선 첫 값: 예전에 직접 고른 값만 한 번 이어받고, 값이 없으면 기본(끔). 두 번째부터는 따로
    @Test func migrate3D() throws {
        let d = try #require(UserDefaults(suiteName: "migrate3D-test"))
        defer { d.removePersistentDomain(forName: "migrate3D-test") }
        d.set(true, forKey: "mapShowSlopes")
        MapLayers.migrate3D(d)
        #expect(d.object(forKey: "mapShowSlopes3D") as? Bool == true)
        d.set(false, forKey: "mapShowSlopes3D"); d.set(true, forKey: "mapShowSlopes")
        MapLayers.migrate3D(d)
        #expect(d.object(forKey: "mapShowSlopes3D") as? Bool == false)
        d.removePersistentDomain(forName: "migrate3D-test")
        MapLayers.migrate3D(d)   // 고른 적 없는 사용자
        #expect(d.object(forKey: "mapShowSlopes3D") == nil)
    }

    func render(_ d: DayMapDrawing) -> Data {
        let size = CGSize(width: 200, height: 300)
        return pixels(size) { d.draw($0, size: size, MapProjection(d.map, rect: CGRect(origin: .zero, size: size)), now: nil) }
    }

    /// 슬로프·리프트를 각각 끄면 그림이 바뀌고, 둘 다 끄면 바탕만 남는다(경로 없음)
    @Test func layersHideLines() throws {
        let map = try #require(SlopeMap.load(resortId: "high1"))
        var d = DayMapDrawing(map: map, route: [], dark: false)
        let all = render(d)
        d.layers.slopes = false
        let noSlopes = render(d)
        d.layers = MapLayers(slopes: true, lifts: false)
        let noLifts = render(d)
        d.layers = .none
        let none = render(d)
        #expect(Set([all, noSlopes, noLifts, none]).count == 4)
        let size = CGSize(width: 200, height: 300)
        #expect(none == pixels(size) { cg in cg.setFillColor(DayMapDrawing.Palette(dark: false).bg.cgColor); cg.fill(CGRect(origin: .zero, size: size)) })
    }

    /// 동영상 프레임은 지도 표시 설정과 상관없이 슬로프·리프트 선이 없다
    @Test func videoIgnoresLayers() throws {
        let map = try #require(SlopeMap.load(resortId: "high1"))
        func frame(_ layers: MapLayers) -> Data {
            var d = DayMapDrawing(map: map, route: [], dark: true)
            d.layers = layers
            let c = ShareVideo.Content(drawing: d, clock: PlayClock([]), title: "t", count: "0회", summary: "")
            return pixels(CGSize(width: 180, height: 320)) { ShareVideo.frame($0, c, size: CGSize(width: 180, height: 320), progress: 0.5) }
        }
        #expect(frame(MapLayers()) == frame(.none))
    }
}
