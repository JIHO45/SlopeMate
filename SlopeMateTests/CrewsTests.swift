import Foundation
import Testing
@testable import SlopeMate

struct CrewsTests {
    @Test func inviteToken() {
        let t = "AbCdEfGhIjKlMnOpQr_-12"
        #expect(Crews.token(from: Crews.inviteURL(t).absoluteString) == t)
        #expect(Crews.token(from: "  \(t)\n") == t)
        #expect(Crews.token(from: "https://slopemate-f9a5b.web.app/i/short") == nil)
        #expect(Crews.token(from: "아무 글") == nil)
    }
}
