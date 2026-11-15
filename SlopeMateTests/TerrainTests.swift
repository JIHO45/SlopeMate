import CoreGraphics
import Testing
@testable import SlopeMate

struct TerrainTests {
    /// 남북으로 뻗은 능선: 서쪽 면과 동쪽 면
    func ridge() -> Terrain {
        let rows = 20, cols = 21
        let z = (0..<rows * cols).map { 1000 - Double(abs($0 % cols - 10)) * 10 }
        return Terrain(north: 37.2, west: 128.8, step: 1.0 / 3600, rows: rows, cols: cols, z: z)
    }

    /// 빛은 화면 왼쪽 위: 북쪽이 위(0)면 서쪽 면이 밝고 동쪽 면이 어둡다. 지도를 180도 돌리면 반대
    @Test func lightFollowsRotation() {
        let t = ridge()
        func side(_ l: [Double], _ c: Int) -> Double { l[10 * t.cols + c] }
        let up = t.light(angle: 0)
        #expect(side(up, 5) > 0.1 && side(up, 15) < -0.1)
        let turned = t.light(angle: .pi)
        #expect(side(turned, 5) < -0.1 && side(turned, 15) > 0.1)
        // 동서로 뻗은 능선: 북쪽이 위면 북쪽 면이 밝고 남쪽 면이 어둡다. 180도 돌리면 반대
        let ew = Terrain(north: 37.2, west: 128.8, step: 1.0 / 3600, rows: 21, cols: 20,
                         z: (0..<21 * 20).map { (i: Int) -> Double in 1000 - Double(abs(i / 20 - 10)) * 10 })
        func row(_ l: [Double], _ r: Int) -> Double { l[r * ew.cols + 10] }
        let n = ew.light(angle: 0)
        #expect(row(n, 5) > 0.1 && row(n, 15) < -0.1)
        let s = ew.light(angle: .pi)
        #expect(row(s, 5) < -0.1 && row(s, 15) > 0.1)
        // 평지는 0
        let flat = Terrain(north: 37.2, west: 128.8, step: 1.0 / 3600, rows: 3, cols: 3, z: Array(repeating: 500, count: 9))
        #expect(flat.light(angle: 0.7).allSatisfy { abs($0) < 1e-9 })
    }

    @Test(arguments: Resort.all.map(\.id))
    func bundledGridLoadsAndLinesUp(resortId: String) throws {
        let t = try #require(Terrain.load(resortId: resortId))
        #expect(t.z.count == t.rows * t.cols)
        #expect(t.z.allSatisfy { (0...2000).contains($0) })
        // 이미지 픽셀 중심이 칸 중심 위경도의 화면 점에 온다(회전 포함)
        let map = try #require(SlopeMap.load(resortId: resortId))
        let proj = MapProjection(map, rect: CGRect(x: 16, y: 100, width: 360, height: 500))
        let layer = Terrain.Layer(terrain: t, image: try #require(t.image(angle: MapProjection.angle(map), dark: false)), minor: CGMutablePath(), major: CGMutablePath())
        let m = layer.imageTransform(proj, .identity)
        for (r, c) in [(0, 0), (t.rows - 1, 3), (t.rows / 2, t.cols - 1)] {
            let a = CGPoint(x: Double(c) + 0.5, y: Double(t.rows - r) - 0.5).applying(m)
            let b = proj.point(t.north - Double(r) * t.step, t.west + Double(c) * t.step)
            #expect(hypot(a.x - b.x, a.y - b.y) < 1e-6)
        }
    }

    /// 동쪽으로 오르는 평면(칸마다 10m, 0~200m): 20m마다 남북 선, 100m 선은 굵은 경로로
    @Test func contoursOnPlane() {
        let t = Terrain(north: 37.2, west: 128.8, step: 1.0 / 3600, rows: 10, cols: 21, z: (0..<210).map { Double($0 % 21) * 10 })
        let (minor, major) = t.contours()
        // 고르기로 가장자리 값이 바뀌지 않는 가운데 행만 본다: 굵은 선은 100m 한 줄(200m는 끝 칸)
        #expect(major.boundingBoxOfPath.minX > 9 * 0.79 && major.boundingBoxOfPath.maxX < 11 * 0.8)
        #expect(!minor.isEmpty)
    }

    @Test func missingResortIsNil() {
        #expect(Terrain.load(resortId: "nowhere") == nil)
    }
}
