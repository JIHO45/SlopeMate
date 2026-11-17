import Foundation
import UIKit

/// 앱에 내장한 고도 격자 (tools/dem/build.py가 만든 maps/dem-<리조트>.json). R50, K; 05-design 4장 "내장 고도 격자와 지형 바탕".
/// 칸 (row, col)의 "중심" 위경도는 (north − row·step, west + col·step). 행은 북쪽부터, 행 안은 서→동.
/// 파일의 heights는 0.1m 단위 Int16 리틀 엔디언(base64). 데이터: Copernicus WorldDEM-30 (출처 문구는 `Terrain.source`).
nonisolated struct Terrain {
    let north, west, step: Double
    let rows, cols: Int
    /// 고도(m), 행 우선
    let z: [Double]

    static let source = "produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved"
    /// 라이선스 6조 (c)가 요구하는 문장 (License-COPDEM-30.pdf, 2026-11-13 원문 대조)
    static let disclaimer = "The organisations in charge of the Copernicus programme by law or by delegation do not incur any liability for any use of the Copernicus WorldDEM-30"
    static let licenseURL = URL(string: "https://documentation.dataspace.copernicus.eu/APIs/SentinelHub/Data/DEM/resources/license/License-COPDEM-30.pdf")!

    private struct File: Decodable { let north, west, step: Double; let rows, cols: Int; let heights: String }

    /// 파일이 없거나 읽지 못하면 nil (바탕 없이 그린다). 3×3 평균으로 한 번 고른다(나무 높이 잡음)
    static func load(resortId: String, bundle: Bundle = .main) -> Terrain? {
        guard let url = bundle.url(forResource: "dem-\(resortId)", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(File.self, from: data),
              let raw = Data(base64Encoded: f.heights), raw.count == f.rows * f.cols * 2, f.rows > 1, f.cols > 1 else { return nil }
        var z = [Double](repeating: 0, count: f.rows * f.cols)
        raw.withUnsafeBytes { b in for i in z.indices { z[i] = Double(Int16(littleEndian: b.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 10 } }
        return Terrain(north: f.north, west: f.west, step: f.step, rows: f.rows, cols: f.cols, z: z).smoothed()
    }

    /// 3×3 평균 (가장자리는 있는 칸만)
    func smoothed() -> Terrain {
        var out = z
        for r in 0..<rows {
            for c in 0..<cols {
                var s = 0.0, n = 0.0
                for i in max(0, r - 1)...min(rows - 1, r + 1) { for j in max(0, c - 1)...min(cols - 1, c + 1) { s += z[i * cols + j]; n += 1 } }
                out[r * cols + c] = s / n
            }
        }
        return Terrain(north: north, west: west, step: step, rows: rows, cols: cols, z: out)
    }

    /// 칸마다 음영 세기: 0 평지, 1 쪽으로 빛을 받는 면, −1 쪽으로 등진 면.
    /// 빛은 화면 왼쪽 위·높이 45도, 고도 1.5배 과장(2D 음영 고정값. 3D는 Terrain3D.exaggeration). angle은 MapProjection.angle(화면 기준 빛을 실제 방위로 돌린다)
    func light(angle: Double) -> [Double] {
        // 화면 왼쪽 위 (u, v) = (−1, 1)/√2 → 동쪽 x, 북쪽 y
        let u = -1 / 2.0.squareRoot(), v = 1 / 2.0.squareRoot()
        let lx = u * cos(angle) + v * sin(angle), ly = -u * sin(angle) + v * cos(angle)
        let el = Double.pi / 4, flat = sin(el), k = 1.5
        let lat = (north - step * Double(rows - 1) / 2) * .pi / 180
        let dy = step * 111_320, dx = dy * cos(lat)
        var out = [Double](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            let r0 = max(0, r - 1), r1 = min(rows - 1, r + 1)
            for c in 0..<cols {
                let c0 = max(0, c - 1), c1 = min(cols - 1, c + 1)
                let zx = (z[r * cols + c1] - z[r * cols + c0]) / (Double(c1 - c0) * dx) * k
                let zy = (z[r0 * cols + c] - z[r1 * cols + c]) / (Double(r1 - r0) * dy) * k // 행은 북쪽부터
                let d = (-zx * lx * cos(el) - zy * ly * cos(el) + flat) / (zx * zx + zy * zy + 1).squareRoot()
                out[r * cols + c] = d >= flat ? (d - flat) / (1 - flat) : max(-1, (d - flat) / flat)
            }
        }
        return out
    }

    /// 가장자리 값: 1 안쪽 … 0 가장자리 (바깥 10%). 2D 음영·등고선이 쓴다(3D는 Terrain3D.edge, 원형)
    func edge(_ r: Int, _ c: Int) -> Double {
        min(1, Double(min(r, rows - 1 - r)) / max(1, Double(rows) * 0.1), Double(min(c, cols - 1 - c)) / max(1, Double(cols) * 0.1))
    }

    /// 가장자리 마스크(회색, 격자 1칸 = 1픽셀, 첫 행이 북쪽). 등고선을 음영처럼 바깥 10%에서 지운다
    func edgeMask() -> CGImage? {
        let px = (0..<rows * cols).map { UInt8(edge($0 / cols, $0 % cols) * 255 + 0.5) }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: cols,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 음영 이미지(격자 1칸 = 1픽셀, 첫 행이 북쪽). 바깥 10%는 바탕색으로 사라진다
    func image(angle: Double, dark: Bool) -> CGImage? {
        let p = DayMapDrawing.Palette(dark: dark)
        func rgb(_ c: UIColor) -> (Double, Double, Double) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (r, g, b)
        }
        let bg = rgb(p.bg), hi = rgb(p.hillLight), lo = rgb(p.hillShadow)
        let l = light(angle: angle)
        var px = [UInt8](repeating: 255, count: rows * cols * 4)
        for r in 0..<rows {
            for c in 0..<cols {
                let s = l[r * cols + c] * edge(r, c), to = s >= 0 ? hi : lo, f = abs(s)
                let i = (r * cols + c) * 4
                px[i] = UInt8((bg.0 + (to.0 - bg.0) * f) * 255 + 0.5)
                px[i + 1] = UInt8((bg.1 + (to.1 - bg.1) * f) * 255 + 0.5)
                px[i + 2] = UInt8((bg.2 + (to.2 - bg.2) * f) * 255 + 0.5)
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 등고선 (marching squares). 경로 좌표는 (col·cos위도, row): 가로세로 같은 길이 단위라 그릴 때 선 굵기를 한 값으로 맞춘다.
    /// 고르기는 음영보다 두 번 더(표면 고도의 나무 높이가 20m 간격과 비슷해 선이 흔들림). (20m 가는 선, 100m 굵은 선)
    func contours(interval: Double = 20, major: Double = 100) -> (minor: CGPath, major: CGPath) {
        let g = smoothed().smoothed()
        let kx = cos((north - step * Double(rows - 1) / 2) * .pi / 180)
        let thin = CGMutablePath(), thick = CGMutablePath()
        let z = g.z
        for r in 0..<rows - 1 {
            for c in 0..<cols - 1 {
                // 모서리: 왼쪽 위, 오른쪽 위, 오른쪽 아래, 왼쪽 아래 (칸마다 배열을 만들지 않는다)
                let z0 = z[r * cols + c], z1 = z[r * cols + c + 1], z2 = z[(r + 1) * cols + c + 1], z3 = z[(r + 1) * cols + c]
                let hi = max(z0, z1, z2, z3)
                var level = (min(z0, z1, z2, z3) / interval).rounded(.up) * interval
                while level <= hi {
                    let path = level.truncatingRemainder(dividingBy: major) == 0 ? thick : thin
                    // 높이가 level을 가로지르는 변의 점. 2점: 선 하나, 4점(안장): 차례로 둘씩
                    var first: CGPoint?
                    func edge(_ a: Double, _ b: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
                        guard (a < level) != (b < level) else { return }
                        let f = (level - a) / (b - a)
                        let p = CGPoint(x: (Double(c) + x0 + (x1 - x0) * f) * kx, y: Double(r) + y0 + (y1 - y0) * f)
                        if let q = first { path.move(to: q); path.addLine(to: p); first = nil } else { first = p }
                    }
                    edge(z0, z1, 0, 0, 1, 0)
                    edge(z1, z2, 1, 0, 1, 1)
                    edge(z2, z3, 1, 1, 0, 1)
                    edge(z3, z0, 0, 1, 0, 0)
                    level += interval
                }
            }
        }
        return (thin, thick)
    }

    /// 화면에 그릴 지형 층. 리조트+밝게/어둡게로 한 번만 만든다(지도는 내장이라 리조트마다 회전각이 하나)
    struct Layer {
        let terrain: Terrain
        let image: CGImage
        let minor, major: CGPath
        /// 등고선 가장자리 마스크(edgeMask). nil이면 자르지 않는다
        var mask: CGImage? = nil
        /// 숲·눈 지형 질감(3D와 같은 Terrain3D.cachedGroundTexture). 있으면 음영·등고선 대신 이것을 깐다
        var ground: CGImage? = nil

        func with(ground: CGImage?) -> Layer { var l = self; l.ground = ground; return l }

        /// 등고선 경로 좌표(col·cos위도, row) → 화면. 투영이 회전·배율·이동뿐이라 세 점으로 정확히 맞는다
        func gridTransform(_ proj: MapProjection, _ t: CGAffineTransform) -> CGAffineTransform {
            let tr = terrain, kx = cos((tr.north - tr.step * Double(tr.rows - 1) / 2) * .pi / 180)
            let p0 = proj.point(tr.north, tr.west).applying(t)
            let px = proj.point(tr.north, tr.west + tr.step / kx).applying(t)
            let py = proj.point(tr.north - tr.step, tr.west).applying(t)
            return CGAffineTransform(a: px.x - p0.x, b: px.y - p0.y, c: py.x - p0.x, d: py.y - p0.y, tx: p0.x, ty: p0.y)
        }

        /// 이미지 사각형(0,0,cols,rows) → 화면. draw(in:)은 첫 행을 사각형의 maxY에 두므로 뒤집고, 픽셀 중심이 칸 중심에 오게 반 칸 옮긴다
        func imageTransform(_ proj: MapProjection, _ t: CGAffineTransform) -> CGAffineTransform {
            let kx = cos((terrain.north - terrain.step * Double(terrain.rows - 1) / 2) * .pi / 180)
            return CGAffineTransform(a: kx, b: 0, c: 0, d: -1, tx: -0.5 * kx, ty: Double(terrain.rows) - 0.5)
                .concatenating(gridTransform(proj, t))
        }
    }

    /// 화면마다 여러 번 불리므로 맞는 것을 찾는 데 드는 일은 사전 조회 하나
    @MainActor static func layer(_ map: SlopeMap, dark: Bool) -> Layer? {
        let key = LayerKey(resortId: map.resortId, dark: dark)
        if let hit = layers[key] { return hit }
        let resortId = map.resortId
        if grids[resortId] == nil { grids[resortId] = .some(load(resortId: resortId)) }
        var layer: Layer?
        if let tr = grids[resortId] ?? nil, let image = tr.image(angle: MapProjection.angle(map), dark: dark) {
            // 등고선은 회전·색과 관계없어 리조트마다 한 번
            let lines = contourCache[resortId] ?? (tr.contours(), tr.edgeMask())
            contourCache[resortId] = lines
            layer = Layer(terrain: tr, image: image, minor: lines.0.minor, major: lines.0.major, mask: lines.1)
        }
        layers[key] = .some(layer)
        return layer
    }
    /// 2D 바탕용 숲·눈 질감. 메시·질감이 무거워 메인 스레드 밖에서 만들고(질감은 파일 캐시, 3D와 같이 씀) 리조트마다 한 번
    @MainActor static func ground(_ map: SlopeMap) async -> CGImage? {
        if let hit = grounds[map.resortId] { return hit }
        if grids[map.resortId] == nil { grids[map.resortId] = .some(load(resortId: map.resortId)) }
        guard let tr = grids[map.resortId] ?? nil else { return nil }
        let image = await Task.detached(priority: .utility) {
            let space = Terrain3D(terrain: tr, map: map)
            return space.cachedGroundTexture(map: map, mesh: space.mesh(), canopy: .load(resortId: map.resortId))
        }.value.image
        grounds[map.resortId] = image
        return image
    }
    @MainActor private static var grounds: [String: CGImage] = [:]
    private struct LayerKey: Hashable { let resortId: String; let dark: Bool }
    @MainActor private static var grids: [String: Terrain?] = [:]
    @MainActor private static var layers: [LayerKey: Layer?] = [:]
    @MainActor private static var contourCache: [String: ((minor: CGPath, major: CGPath), CGImage?)] = [:]
}
