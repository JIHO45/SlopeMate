import Foundation
import Testing
@testable import SlopeMate

struct SeasonTicketViewTests {
    func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "+09:00")! }

    @Test func untilIsDayBeforeExclusiveEnd() {
        let end = SeasonTicket.expiry(purchase: at("2026-11-20T10:00:00"))
        #expect(SeasonTicketView.untilText(end) == "2027년 4월 30일까지")
        #expect(SeasonTicketView.seasonText(end) == "2026-27 시즌")
        // 5월 구입은 다음 시즌
        let next = SeasonTicket.expiry(purchase: at("2027-05-01T00:30:00"))
        #expect(SeasonTicketView.untilText(next) == "2028년 4월 30일까지")
        #expect(SeasonTicketView.seasonText(next) == "2027-28 시즌")
    }

    @Test func expiredTicketShowsNextPurchasePeriod() {
        let old = SeasonTicket.expiry(purchase: at("2026-11-20T10:00:00"))
        let shown = SeasonTicketView.shownExpiry(active: false, expiry: old, now: at("2027-05-02T09:00:00"))
        #expect(SeasonTicketView.untilText(shown) == "2028년 4월 30일까지")
        #expect(SeasonTicketView.seasonText(shown) == "2027-28 시즌")
        #expect(SeasonTicketView.shownExpiry(active: true, expiry: old, now: at("2027-05-02T09:00:00")) == old)
    }

    @Test func priceTextUsesDisplayPrice() {
        #expect(SeasonTicketView.priceText(displayPrice: "₩9,900", currencyCode: "KRW") == "9,900원")
        #expect(SeasonTicketView.priceText(displayPrice: "9,900원", currencyCode: "KRW") == "9,900원")
        #expect(SeasonTicketView.priceText(displayPrice: "$6.99", currencyCode: "USD") == "$6.99")
    }

    @Test func restoreFailedFallsBackOnGenericMessage() {
        #expect(SeasonTicketView.restoreFailedText("") == "잠시 뒤 다시 시도해 주세요.")
        #expect(SeasonTicketView.restoreFailedText("요청을 완료할 수 없음") == "잠시 뒤 다시 시도해 주세요.")
        #expect(SeasonTicketView.restoreFailedText("인터넷 연결이 오프라인 상태입니다.") == "인터넷 연결이 오프라인 상태입니다.")
    }
}
