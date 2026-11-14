import Foundation
import StoreKit

/// 시즌 이용권(R54, L). 기간 고정 구독 상품 하나. 서버 없이 기기의 StoreKit 거래로 이용권을 계산한다(05-design 6장).
@Observable final class SeasonTicket {
    static let productID = "com.Joe.SlopeMate.seasonticket"

    enum Status: Equatable {
        case idle, purchasing
        /// 보호자 승인 등. 승인되면 Transaction.updates로 들어온다
        case pending
        /// 구입은 됐지만 서명을 확인하지 못함. 구입 복원으로 다시 확인
        case unverified
        /// 구입 복원했지만 이 Apple 계정에 유효한 이용권이 없음
        case nothingToRestore
        /// 시스템 오류 문구
        case failed(String)
    }

    private(set) var product: Product?
    /// 가장 늦게 끝나는 유효 이용권의 끝(배타적, 한국 5월 1일 00:00). 없으면 nil
    private(set) var expiry: Date?
    /// 환불되지 않은 이용권의 시즌("2026-27" 형식, Stats.season과 같음)
    private(set) var seasons: Set<String> = []
    var status: Status = .idle

    var isActive: Bool { Self.isActive(expiry: expiry) }

    /// 유료 기능은 보고 있는 기록의 시즌에 이용권을 샀을 때만 연다(decisions 2026-11-14)
    func owns(season: String) -> Bool { seasons.contains(season) }

    @ObservationIgnored private var updates: Task<Void, Never>?
    /// 늦게 끝난 옛 refresh가 새 결과를 덮지 않게
    @ObservationIgnored private var refreshGeneration = 0

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let t) = result { await t.finish() }
                await self.refresh()
                if self.status == .pending, self.isActive { self.status = .idle }
            }
        }
        Task { await load() }
    }

    deinit { updates?.cancel() }

    /// 상품과 이용권을 불러온다. 상품을 못 불러와도(오프라인) 이용권 계산은 거래 기록으로 한다
    func load() async {
        await refresh()
        product = try? await Product.products(for: [Self.productID]).first
    }

    /// 앱이 앞으로 올 때도 부른다(켜 둔 채 5월 1일을 넘기면 잠금이 바로 보이게)
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        var dates: [(purchase: Date, revoked: Date?)] = []
        // currentEntitlements는 상품별 최신 거래 하나뿐이라 그것만 환불되면 앞 거래까지 잠긴다. 모든 거래에서 환불을 빼고 계산한다
        for await result in Transaction.all {
            // ponytail: 서명 확인 실패 거래는 이용권으로 치지 않음(서버 검증 없음, decisions 2026-11-14)
            guard case .verified(let t) = result, t.productID == Self.productID else { continue }
            dates.append((t.purchaseDate, t.revocationDate))
        }
        guard generation == refreshGeneration else { return }
        expiry = Self.expiry(of: dates)
        seasons = Self.seasons(of: dates)
    }

    func purchase() async {
        guard status != .purchasing, !isActive else { return }
        guard let product else { status = .failed("상품 정보를 불러오지 못했어요. 인터넷 연결을 확인해 주세요."); return }
        status = .purchasing
        do {
            switch try await product.purchase() {
            case .success(.verified(let t)):
                await t.finish()
                await refresh()
                status = .idle
            case .success(.unverified):
                status = .unverified
            case .pending:
                status = .pending
            case .userCancelled:
                status = .idle
            @unknown default:
                status = .idle
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// 구입 복원. Apple 계정 로그인 창이 뜰 수 있어 사용자가 누를 때만 부른다
    /// 결제 대기 중이면 복원할 것이 없거나 취소해도 대기 안내를 유지한다
    func restore() async {
        let wasPending = status == .pending
        do {
            try await AppStore.sync()
            await refresh()
            status = isActive ? .idle : wasPending ? .pending : .nothingToRestore
        } catch StoreKitError.userCancelled {
            status = wasPending ? .pending : .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

nonisolated extension SeasonTicket {
    private static var seoul: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }

    /// 구입일이 속한 시즌의 끝. 1~4월 구입은 그해, 5~12월 구입은 다음 해 4월 30일이 끝이며,
    /// 4월 30일 하루를 다 쓰도록 다음 날 5월 1일 00:00(한국)을 배타적 끝으로 돌려준다.
    static func expiry(purchase: Date) -> Date {
        let c = seoul.dateComponents([.year, .month], from: purchase)
        let y = c.month! <= 4 ? c.year! : c.year! + 1
        return seoul.date(from: DateComponents(year: y, month: 5, day: 1))!
    }

    /// 환불된 거래는 빼고 가장 늦은 끝
    static func expiry(of transactions: [(purchase: Date, revoked: Date?)]) -> Date? {
        transactions.filter { $0.revoked == nil }.map { expiry(purchase: $0.purchase) }.max()
    }

    /// 끝이 Y년 5월 1일인 이용권은 (Y-1)-Y 시즌
    static func season(purchase: Date) -> String {
        let y = seoul.component(.year, from: expiry(purchase: purchase))
        return String(format: "%d-%02d", y - 1, y % 100)
    }

    static func seasons(of transactions: [(purchase: Date, revoked: Date?)]) -> Set<String> {
        Set(transactions.filter { $0.revoked == nil }.map { season(purchase: $0.purchase) })
    }

    static func isActive(expiry: Date?, now: Date = .now) -> Bool {
        expiry.map { now < $0 } ?? false
    }
}
