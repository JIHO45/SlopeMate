import Testing
@testable import SlopeMate

struct SlopeMateTests {
    @Test func resortsLoad() {
        #expect(Resort.all.count == 12)
        #expect(Set(Resort.all.map(\.id)).count == 12)
    }
}
