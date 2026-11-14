import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import SlopeMate

struct SeasonTicketTests {
    let f = ISO8601DateFormatter()
    func at(_ s: String) -> Date { f.date(from: s + "+09:00")! }

    @Test func expiryIsSeasonEndInKorea() {
        let may1 = at("2027-05-01T00:00:00")
        #expect(SeasonTicket.expiry(purchase: at("2026-11-20T10:00:00")) == may1)
        #expect(SeasonTicket.expiry(purchase: at("2027-01-01T00:00:00")) == may1)
        #expect(SeasonTicket.expiry(purchase: at("2027-04-30T23:59:59")) == may1)
        // 5~10월 구입은 다음 시즌 끝까지
        #expect(SeasonTicket.expiry(purchase: at("2027-05-01T00:00:00")) == at("2028-05-01T00:00:00"))
        #expect(SeasonTicket.expiry(purchase: at("2026-10-31T23:59:00")) == may1)
        // UTC로는 4월 30일 15:30이지만 한국은 5월 1일
        #expect(SeasonTicket.expiry(purchase: at("2027-05-01T00:30:00")) == at("2028-05-01T00:00:00"))
    }

    @Test func activeThroughApril30() {
        let e = SeasonTicket.expiry(purchase: at("2026-12-01T09:00:00"))
        #expect(SeasonTicket.isActive(expiry: e, now: at("2027-04-30T23:59:59")))
        #expect(!SeasonTicket.isActive(expiry: e, now: at("2027-05-01T00:00:00")))
        #expect(!SeasonTicket.isActive(expiry: nil))
    }

    @Test func refundLocksAndLatestWins() {
        let old = at("2025-12-01T09:00:00"), new = at("2026-12-01T09:00:00")
        #expect(SeasonTicket.expiry(of: [(new, at("2026-12-02T09:00:00"))]) == nil)
        #expect(SeasonTicket.expiry(of: [(old, nil), (new, nil)]) == at("2027-05-01T00:00:00"))
        #expect(SeasonTicket.expiry(of: [(old, nil), (new, at("2026-12-02T09:00:00"))]) == at("2026-05-01T00:00:00"))
    }

    @Test func seasonOfPurchase() {
        #expect(SeasonTicket.season(purchase: at("2027-04-30T23:59:00")) == "2026-27")
        #expect(SeasonTicket.season(purchase: at("2027-05-01T00:00:00")) == "2027-28")
        #expect(SeasonTicket.season(purchase: at("2026-11-20T10:00:00")) == "2026-27")
        #expect(SeasonTicket.season(purchase: at("2026-10-31T23:59:00")) == "2026-27")
        // 시즌 표현이 기록 쪽(Stats.season)과 같은지
        #expect(SeasonTicket.season(purchase: at("2026-12-05T10:00:00")) == Stats.season(of: at("2026-12-05T06:00:00")))
        let s = SeasonTicket.seasons(of: [(at("2025-12-01T09:00:00"), nil),
                                         (at("2026-12-01T09:00:00"), at("2026-12-02T09:00:00"))])
        #expect(s == ["2025-26"])
    }

    /// StoreKit 설정 파일로 상품·구입·결제 대기·환불 흐름
    @Test @MainActor func storeKitFlow() async throws {
        let session = try SKTestSession(configurationFileNamed: "SeasonTicket")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        defer { session.clearTransactions() }

        let ticket = SeasonTicket()
        await ticket.load()
        // 새 시뮬레이터 첫 실행은 호스트 앱이 먼저 실제 App Store에 물어 빈 응답이 올 수 있어 다시 묻는다
        for _ in 0..<10 where ticket.product == nil {
            try await Task.sleep(for: .milliseconds(500))
            await ticket.load()
        }
        let product = try #require(ticket.product)
        #expect(product.type == .nonRenewable)
        #expect(product.displayName == "시즌 이용권")
        #expect(!ticket.isActive)

        await ticket.purchase()
        #expect(ticket.status == .idle)
        #expect(ticket.isActive)
        #expect(ticket.expiry == SeasonTicket.expiry(purchase: .now))

        // 환불되면 잠금. 환불은 Transaction.updates로 늦게 들어온다
        let t = try #require(session.allTransactions().first { $0.productIdentifier == SeasonTicket.productID && $0.state == .purchased })
        try session.refundTransaction(identifier: t.identifier)
        // refresh를 부르지 않고 Transaction.updates 리스너만 기다린다
        for _ in 0..<30 where ticket.isActive {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!ticket.isActive)

        // 실패
        session.failTransactionsEnabled = true
        await ticket.purchase()
        if case .failed = ticket.status {} else { Issue.record("실패 상태가 아님: \(ticket.status)") }
        #expect(!ticket.isActive)
        session.failTransactionsEnabled = false

        // 결제 대기(보호자 승인) → 승인되면 updates 리스너로 열림.
        // 테스트 환경은 대기 거래도 Transaction.all에 넣어 승인 전 잠김은 실기기에서 확인(decisions 2026-11-14)
        session.askToBuyEnabled = true
        await ticket.purchase()
        #expect(ticket.status == .pending)
        let deferred = try #require(session.allTransactions().first { $0.state == .deferred })
        try session.approveAskToBuyTransaction(identifier: deferred.identifier)
        for _ in 0..<30 where ticket.status == .pending {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(ticket.status == .idle)
        #expect(ticket.isActive)
    }
}
