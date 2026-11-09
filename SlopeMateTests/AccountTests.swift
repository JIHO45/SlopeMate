import Testing
@testable import SlopeMate

struct AccountTests {
    @Test func displayName() {
        #expect(Account.cleanName("  지호 ") == "지호")
        #expect(Account.cleanName("   ") == nil)
        #expect(Account.cleanName(String(repeating: "가", count: 20)) != nil)
        #expect(Account.cleanName(String(repeating: "가", count: 21)) == nil)
    }
}
