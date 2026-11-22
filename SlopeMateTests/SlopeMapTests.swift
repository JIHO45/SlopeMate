import Testing
@testable import SlopeMate

struct SlopeMapTests {
    @Test(arguments: Resort.all.map(\.id))
    func bundledMapLoads(resortId: String) throws {
        let map = try #require(SlopeMap.load(resortId: resortId))
        #expect(map.resortId == resortId)
        #expect(!map.slopes.isEmpty && !map.lifts.isEmpty)
        #expect(Set(map.slopes.map(\.id)).count == map.slopes.count)
        #expect(map.slopes.allSatisfy { $0.lines.allSatisfy { $0.count >= 2 } })
    }

    @Test func missingResortIsNil() {
        #expect(SlopeMap.load(resortId: "nowhere") == nil)
    }

    /// 그린 선: 연결된 슬로프는 ID·이름 유지에 그린 선·색, 연결 안 된 선은 새 ID, 그리지 않은 OSM 슬로프는 빠짐
    @Test func drawnLinesReplaceOSM() {
        let osm = [SlopeMap.Slope(id: "r-s01", name: "A", difficulty: "easy", osmIds: ["way/1"], lines: [[[0, 0], [1, 1]]], area: nil),
                   SlopeMap.Slope(id: "r-s02", name: "B", difficulty: "easy", osmIds: ["way/2"], lines: [[[0, 0], [2, 2]]], area: true)]
        let drawn = [SlopeMap.Drawn(slope: "r-s01", difficulty: "advanced", line: [[0, 0], [0.5, 0.6], [1, 1]]),
                     SlopeMap.Drawn(slope: "r-s01", difficulty: "advanced", line: [[1, 1], [1.2, 1.5]]),
                     SlopeMap.Drawn(slope: "r-s01", difficulty: "easy", line: [[5, 5], [6, 6]]),   // 같은 슬로프에 색이 다른 선
                     SlopeMap.Drawn(slope: nil, difficulty: "expert", line: [[3, 3], [4, 4]])]
        let out = SlopeMap.drawn(drawn, osm: osm, resortId: "r")
        #expect(out.map(\.id) == ["r-s01", "r-d01", "r-d02"])
        #expect(out[0].name == "A" && out[0].difficulty == "advanced" && out[0].lines.count == 2 && out[0].osmIds == ["way/1"])
        #expect(out[1].name == nil && out[1].difficulty == "easy")
        #expect(out[2].name == nil && out[2].difficulty == "expert")
    }

    /// 선의 name이 OSM 이름을 덮고, 연결 안 된 선에도 이름이 붙고, closed 선은 숨는다
    @Test func drawnNamesAndClosed() {
        let osm = [SlopeMap.Slope(id: "r-s01", name: "A", difficulty: "easy", osmIds: ["way/1"], lines: [[[0, 0], [1, 1]]], area: nil),
                   SlopeMap.Slope(id: "r-s02", name: "B", difficulty: "easy", osmIds: ["way/2"], lines: [[[0, 0], [2, 2]]], area: nil)]
        let drawn = [SlopeMap.Drawn(slope: "r-s01", difficulty: "easy", line: [[0, 0], [1, 1]], name: "가"),
                     SlopeMap.Drawn(slope: "r-s02", difficulty: "easy", line: [[0, 0], [2, 2]], closed: true),
                     SlopeMap.Drawn(slope: nil, difficulty: "expert", line: [[3, 3], [4, 4]], name: "나")]
        let out = SlopeMap.drawn(drawn, osm: osm, resortId: "r")
        #expect(out.map(\.id) == ["r-s01", "r-d01"])
        #expect(out[0].name == "가" && out[1].name == "나")
    }
}
