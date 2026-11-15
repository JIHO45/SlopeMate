import UIKit
import Testing
@testable import SlopeMate

struct MapStyleTests {
    @Test func levelMapping() {
        #expect(SlopeStyle.level("novice") == .beginner)
        #expect(SlopeStyle.level("easy") == .beginner)
        #expect(SlopeStyle.level("intermediate") == .intermediate)
        #expect(SlopeStyle.level("advanced") == .advanced)
        for s in ["expert", "freeride", "extreme"] { #expect(SlopeStyle.level(s) == .expert) }
        #expect(SlopeStyle.level(nil) == .unknown)
        #expect(SlopeStyle.level("weird") == .unknown)
        #expect(SlopeStyle.label(.expert) == "최상급")
        #expect(SlopeStyle.label(.unknown) == nil)
    }

    @Test func colors() {
        #expect(SlopeStyle.hex(.beginner, dark: false) == 0x2E9E4F)
        #expect(SlopeStyle.hex(.beginner, dark: true) == 0x4CC46F)
        #expect(SlopeStyle.hex(.intermediate, dark: true) == 0x7C8FF0)
        #expect(SlopeStyle.hex(.advanced, dark: false) == 0xD93A3A)
        #expect(SlopeStyle.hex(.expert, dark: true) == 0x111418)
        #expect(SlopeStyle.hex(.unknown, dark: false) == 0x7C8A90)
        #expect(SlopeStyle.casing(.expert, dark: true) == 0xC4D3DA)
        #expect(SlopeStyle.casing(.expert, dark: false) == nil)
        #expect(SlopeStyle.casing(.advanced, dark: true) == nil)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        SlopeStyle.color(difficulty: "advanced", dark: false).getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(Int((r * 255).rounded()) == 0xD9 && Int((g * 255).rounded()) == 0x3A)
    }

    /// 좌표를 그대로 화면 좌표로: [위도, 경도] → (x: 경도, y: 위도)
    func map() -> SlopeMap {
        typealias S = SlopeMap.Slope
        return SlopeMap(resortId: "t", source: "", osmTimestamp: "", slopes: [
            S(id: "a", name: "A", difficulty: "easy", osmIds: [], lines: [[[0, 0], [0, 100]]], area: nil),
            S(id: "b", name: nil, difficulty: nil, osmIds: [], lines: [[[30, 0], [30, 100]]], area: nil),
            S(id: "c", name: "C", difficulty: "advanced", osmIds: [],
              lines: [[[200, 0], [200, 100], [300, 100], [300, 0], [200, 0]]], area: true),
        ], lifts: [])
    }
    func project(_ c: [Double]) -> CGPoint? { CGPoint(x: c[1], y: c[0]) }

    @Test func pick() {
        let m = map()
        let hit = SlopePick.nearest(to: CGPoint(x: 50, y: 10), in: m, project: project)
        #expect(hit == .init(slopeId: "a", name: "A", difficulty: "easy", anchor: CGPoint(x: 50, y: 0)))
        #expect(SlopePick.nearest(to: CGPoint(x: 50, y: 20), in: m, project: project)?.slopeId == "b")
        #expect(SlopePick.nearest(to: CGPoint(x: 50, y: 53), in: m, project: project) == nil)
        #expect(SlopePick.nearest(to: CGPoint(x: 150, y: 10), in: m, project: project) == nil)
        // 면 안쪽: 테두리에서 50 떨어져도 맞음, anchor는 누른 점
        let inner = SlopePick.nearest(to: CGPoint(x: 50, y: 250), in: m, project: project)
        #expect(inner?.slopeId == "c" && inner?.anchor == CGPoint(x: 50, y: 250))
        #expect(inner?.area == true && hit?.area == false)
        // 보이지 않는 점에 걸친 선분은 건너뜀
        #expect(SlopePick.nearest(to: CGPoint(x: 50, y: 10), in: m, project: { $0[0] == 0 ? nil : project($0) })?.slopeId == "b")
    }
}
