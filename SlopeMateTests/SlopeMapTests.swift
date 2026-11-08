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
}
