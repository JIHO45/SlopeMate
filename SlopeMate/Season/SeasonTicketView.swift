import SwiftUI
import StoreKit

/// S18 시즌 이용권 (R54, 07-visual-design 6장 C 확정: v5 맨 위·결제 대기, v4 어둡게·전체 길이·가장 큰 글씨, 상태 v2, 이미 있음 v3).
/// 잠긴 기능·S17·S20에서 시트로 연다. 구입·복원·코드로 이용권이 생기면 시트를 닫아 원래 화면으로 돌아간다.
struct SeasonTicketView: View {
    @Environment(SeasonTicket.self) private var ticket
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var redeeming = false
    /// 마지막 동작이 구입 복원이었는지(실패 안내를 고른다)
    @State private var restoring = false
    /// 구입 복원이 도는 중(중복 누름 방지)
    @State private var restoreBusy = false
    /// 첫 프레임에 "상품 정보를 받지 못했어요"가 번쩍이지 않게 받기 전에는 불러오는 중으로 둔다
    @State private var loading = true
    @ScaledMetric(relativeTo: .largeTitle) private var priceSize: CGFloat = 40

    private var big: Bool { typeSize.isAccessibilitySize }
    private var expiry: Date { Self.shownExpiry(active: ticket.isActive, expiry: ticket.expiry, now: .now) }
    private var price: String? { ticket.product.map { Self.priceText($0) } }

    var body: some View {
        Group {
            if ticket.isActive { owned } else { store }
        }
        .foregroundStyle(Color.primaryText)
        .background(Color.bg)
        .offerCodeRedemption(isPresented: $redeeming) { result in
            if case .failure(let error) = result {
                restoring = false
                ticket.status = .failed(error.localizedDescription)
            } else {
                Task { await ticket.refresh() }
            }
        }
        .onChange(of: ticket.isActive) { _, on in if on { dismiss() } }
        .task { if ticket.product == nil { await reload() } else { loading = false } }
        // 실패 안내는 다음에 열 때 남기지 않는다
        .onDisappear {
            switch ticket.status {
            case .failed, .nothingToRestore: ticket.status = .idle
            default: break
            }
        }
    }

    // MARK: 구입 전

    private var store: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                priceBlock.padding(.top, 14)
                if !big {
                    Text("이용권으로 여는 기능").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 4).padding(.top, 18).padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                }
                VStack(spacing: 12) { ForEach(Self.features) { featureCard($0) } }
                    .padding(.top, big ? 18 : 0)
                footer.padding(.top, 14)
            }
            .padding(.horizontal, big ? 20 : 16).padding(.top, 20).padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    }

    @ViewBuilder private var header: some View {
        let title = Text("시즌 이용권").font(.title.bold()).accessibilityAddTraits(.isHeader)
        if big {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Spacer(); closeButton }
                title
            }
        } else {
            HStack(spacing: 12) {
                title.padding(.leading, 4).frame(maxWidth: .infinity, alignment: .leading)
                closeButton
            }
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark").font(.body.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxLarge) // 원 안에 머물게
                .frame(width: 44, height: 44).glassCircle()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("닫기")
    }

    @ViewBuilder private var priceBlock: some View {
        if big {
            // 가장 큰 글씨: 얼음색 카드 없이 가격·기간을 세로로
            VStack(alignment: .leading, spacing: 0) {
                Text(price ?? "가격을 불러오지 못했어요")
                    .font(price == nil ? .title2.bold() : .largeTitle.bold()).monospacedDigit()
                    .foregroundStyle(price == nil ? Color.primaryText : Color.accentText)
                Text(Self.untilText(expiry)).font(.title2.weight(.semibold))
                Text("자동으로 갱신되지 않아요").font(.title3).foregroundStyle(Color.secondaryText)
                if let note = Self.firstSeasonNote(expiry, price: price) { Text(note).font(.title3).foregroundStyle(Color.secondaryText) }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.seasonText(expiry)).font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
                    if let price {
                        // "9,900원": 숫자는 크게, "원"은 작게
                        let won = price.hasSuffix("원")
                        Text("\(Text(won ? String(price.dropLast()) : price))\(Text(won ? "원" : "").font(.system(size: priceSize * 0.55, weight: .bold)))")
                            .font(.system(size: priceSize, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Color.accentText).lineLimit(1).minimumScaleFactor(0.6)
                    } else {
                        Text("가격을 불러오지\n못했어요").font(.headline)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Self.untilText(expiry)).font(.subheadline.bold())
                    Text("한 번 결제").font(.footnote).foregroundStyle(Color.secondaryText)
                    Text("자동으로 갱신되지 않아요").font(.footnote).foregroundStyle(Color.secondaryText)
                }
                .multilineTextAlignment(.trailing)
            }
            if let note = Self.firstSeasonNote(expiry, price: price) {
                Text(note).font(.footnote).foregroundStyle(Color.secondaryText)
            }
            }
            .padding(.vertical, 16).padding(.horizontal, 20)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 24))
            .accessibilityElement(children: .combine)
        }
    }

    private func featureCard(_ f: Feature) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FeatureArt(feature: f).frame(height: 440).frame(maxWidth: .infinity).clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(f.title).font(.headline)
                Text(f.detail).font(.footnote).foregroundStyle(Color.secondaryText)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .card(padding: 0)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var footer: some View {
        let free = Text("기록과 기본 기능은 계속 무료예요.")
        let refund = Text("환불은 Apple에서 처리해요.")
        if big {
            VStack(alignment: .leading, spacing: 8) {
                free
                // 가장 큰 글씨에서는 구입 복원·코드 입력을 아래 고정에서 여기로 내린다
                VStack(spacing: 8) {
                    wideButton("구입 복원", busy: restoreBusy, action: restore)
                    wideButton("코드 입력") { redeeming = true }
                }
                .disabled(ticket.status == .purchasing)
                .padding(.top, 6)
                VStack(alignment: .leading, spacing: 0) {
                    Link(destination: SettingsView.termsURL) { Text("이용약관").underline().frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                    if let url = SettingsView.privacyPolicyURL {
                        Link(destination: url) { Text("개인정보처리방침").underline().frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                    }
                }
                .multilineTextAlignment(.leading)
                refund
            }
            .foregroundStyle(Color.secondaryText)
        } else {
            VStack(spacing: 6) {
                free
                HStack(spacing: 4) {
                    Link(destination: SettingsView.termsURL) { Text("이용약관").underline().frame(minHeight: 44).contentShape(Rectangle()) }
                    if let url = SettingsView.privacyPolicyURL {
                        Text("·")
                        Link(destination: url) { Text("개인정보처리방침").underline().frame(minHeight: 44).contentShape(Rectangle()) }
                    }
                }
                refund
            }
            .font(.footnote).foregroundStyle(Color.secondaryText)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
    }

    private func wideButton(_ title: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label(title, busy: busy).font(.title3.weight(.semibold)).foregroundStyle(Color.accentText)
                .padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 64)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    @ViewBuilder private func label(_ title: String, busy: Bool) -> some View {
        if busy { ProgressView().accessibilityLabel("\(title) 중") } else { Text(title) }
    }

    // MARK: 아래 고정: 안내 + 구입 버튼 (+ 구입 복원 | 코드 입력)

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if let notice { noticeView(notice).padding(.bottom, 12) }
            mainButton
            if !big {
                HStack(spacing: 0) {
                    linkButton("구입 복원", busy: restoreBusy, action: restore)
                    Rectangle().fill(Color.cardBorder).frame(width: 1, height: 16).accessibilityHidden(true)
                    linkButton("코드 입력") { redeeming = true }
                }
                .disabled(ticket.status == .purchasing)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, big ? 12 : 0)
        .background(Color.bg)
        .overlay(alignment: .top) { Color.rowDivider.frame(height: 1) }
    }

    private func linkButton(_ title: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label(title, busy: busy).font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentText)
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    @ViewBuilder private var mainButton: some View {
        let height: CGFloat = big ? 88 : 60
        if ticket.status == .pending {
            Button {} label: {
                Text("승인 기다리는 중")
                    .font(.title3.bold()).foregroundStyle(Color.secondaryText)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: height)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 24))
            }
            .buttonStyle(.plain)
            .disabled(true)
        } else if let price {
            Button {
                restoring = false
                Task { await ticket.purchase() }
            } label: {
                if ticket.status == .purchasing { ProgressView().tint(Color.onAccent) }
                else { Text(purchaseFailed ? "다시 시도 · \(price)" : "\(price)에 구입") }
            }
            .buttonStyle(PrimaryButtonStyle(minHeight: height))
            .disabled(ticket.status == .purchasing || restoreBusy)
        } else {
            Button { Task { await reload() } } label: {
                if loading { ProgressView().tint(Color.onAccent) } else { Text("다시 시도") }
            }
            .buttonStyle(PrimaryButtonStyle(minHeight: height))
            .disabled(loading)
        }
    }

    private enum Notice: Equatable { case pending, failed(String), unverified, noRestore, restoreFailed(String), noProduct }

    private var purchaseFailed: Bool { if case .failed? = notice { true } else { false } }

    private var notice: Notice? {
        switch ticket.status {
        case .pending: return .pending
        case .unverified: return .unverified
        case .nothingToRestore: return .noRestore
        case .failed(let message): return restoring ? .restoreFailed(message) : .failed(message)
        case .idle, .purchasing:
            return ticket.product == nil && !loading ? .noProduct : nil
        }
    }

    private func noticeView(_ n: Notice) -> some View {
        let danger = switch n { case .failed, .restoreFailed, .unverified: true; default: false }
        let (icon, iconColor, title, detail): (String, Color, String, String) = switch n {
        case .pending: ("clock", .windAmber, "결제 승인을 기다리고 있어요", "승인되면 열려요. 기록은 그대로 쓸 수 있어요.")
        case .failed: ("exclamationmark.triangle", AccountDeleteSheet.dangerText, "구입하지 못했어요", "결제되지 않았어요. 다시 시도해 주세요.")
        case .unverified: ("exclamationmark.triangle", AccountDeleteSheet.dangerText, "구입을 확인하지 못했어요", "구입 복원을 눌러 주세요.")
        case .noRestore: ("info.circle", .accentText, "복원할 이용권이 없어요", "구입할 때 쓴 Apple 계정인지 확인해 주세요.")
        case .restoreFailed(let m): ("exclamationmark.triangle", AccountDeleteSheet.dangerText, "복원하지 못했어요", Self.restoreFailedText(m))
        case .noProduct: ("info.circle", .accentText, "상품 정보를 받지 못했어요", "인터넷 연결을 확인하고 다시 시도해 주세요.")
        }
        return HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(iconColor).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(danger ? AccountDeleteSheet.dangerText : Color.primaryText)
                // 가장 큰 글씨에서는 버튼 위 안내가 화면을 다 덮지 않게 제목 한 줄만
                if !big {
                    Text(detail).font(.footnote)
                        .foregroundStyle(danger ? AccountDeleteSheet.dangerText : Color.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(danger ? Color.dangerFill : Color.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(danger ? Color.clear : Color.cardBorder))
        .accessibilityElement(children: .combine)
    }

    private func restore() {
        guard !restoreBusy else { return }
        restoring = true
        restoreBusy = true
        Task {
            await ticket.restore()
            restoreBusy = false
        }
    }

    private func reload() async {
        loading = true
        await ticket.load()
        loading = false
    }

    // MARK: 이미 있음 (v3)

    private var owned: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                HStack(spacing: 14) {
                    Image(systemName: "checkmark").font(.title3.weight(.bold)).foregroundStyle(Color.onAccent)
                        .frame(width: 48, height: 48).background(Color.accentFill, in: Circle()).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Self.untilText(expiry))\n쓰고 있어요").font(.title3.bold())
                        Text("자동으로 갱신되지 않아요").font(.subheadline).foregroundStyle(Color.secondaryText)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 20))
                .accessibilityElement(children: .combine)
                .padding(.top, 16)
                Text("열린 기능").font(.footnote).foregroundStyle(Color.secondaryText)
                    .padding(.leading, 16).padding(.top, 20).padding(.bottom, 6)
                VStack(spacing: 0) {
                    ForEach(Self.features) { f in
                        HStack(spacing: 12) {
                            IconCircle(systemName: f.icon, size: 36)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(f.title).font(.headline)
                                Text(f.short).font(.footnote).foregroundStyle(Color.secondaryText)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 56)
                        .accessibilityElement(children: .combine)
                        if f.id != Self.features.last?.id { Color.rowDivider.frame(height: 1) }
                    }
                }
                .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
            }
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("닫기") { dismiss() }.buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 16).padding(.vertical, 12).background(Color.bg)
        }
    }
}

// MARK: 문구

extension SeasonTicketView {
    private static var seoul: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }

    /// 쓰는 중이면 그 이용권의 끝, 없거나 만료됐으면 지금 사면 쓸 수 있는 끝
    static func shownExpiry(active: Bool, expiry: Date?, now: Date) -> Date {
        if active, let expiry { return expiry }
        return SeasonTicket.expiry(purchase: now)
    }

    /// "2027년 4월 30일까지". expiry는 배타적 끝(5월 1일 00:00 한국)이라 그 직전 날을 쓴다
    static func untilText(_ expiry: Date) -> String {
        let d = seoul.dateComponents([.year, .month, .day], from: expiry.addingTimeInterval(-1))
        return "\(d.year!)년 \(d.month!)월 \(d.day!)일까지"
    }

    /// "2026-27 시즌"
    static func seasonText(_ expiry: Date) -> String {
        let y = seoul.component(.year, from: expiry.addingTimeInterval(-1))
        return String(format: "%d-%02d 시즌", y - 1, y % 100)
    }

    /// 첫 시즌(2026-27)을 파는 동안만, 원화 가격일 때만 보이는 안내. 다음 시즌 가격은 decisions 2026-11-17
    static func firstSeasonNote(_ expiry: Date, price: String?) -> String? {
        seasonText(expiry) == "2026-27 시즌" && price?.hasSuffix("원") == true ? "첫 시즌 가격이에요. 다음 시즌부터 9,900원" : nil
    }

    /// 원화는 시안처럼 "9,900원", 그 밖의 통화는 StoreKit 표기 그대로.
    /// product.price는 StoreKit 설정 실행에서 9로 오기도 해서 결제 시트와 같은 displayPrice를 근거로 한다
    static func priceText(_ product: Product) -> String {
        priceText(displayPrice: product.displayPrice, currencyCode: product.priceFormatStyle.currencyCode)
    }

    static func priceText(displayPrice: String, currencyCode: String) -> String {
        guard currencyCode == "KRW" else { return displayPrice }
        let digits = displayPrice.filter { $0.isNumber || $0 == "," }
        return digits.isEmpty ? displayPrice : digits + "원"
    }

    /// 복원 실패 설명: 시스템 문구가 비었거나 일반 문구면 시안 문구로
    static func restoreFailedText(_ message: String) -> String {
        let generic = ["완료할 수 없", "couldn’t be completed", "couldn't be completed"]
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty || generic.contains(where: m.contains) ? "잠시 뒤 다시 시도해 주세요." : m
    }
}

// MARK: 여는 기능 (시즌 목표는 무료, 내 리프트 대기는 켜진 뒤 카드를 더한다)

struct Feature: Identifiable {
    /// 미리보기 그림 에셋 이름(Assets에 밝게·어둡게 Appearance로)
    let id: String
    let title, detail, short, icon: String
}

extension SeasonTicketView {
    static let features = [
        Feature(id: "ticket-3d", title: "3D 보기", detail: "하루 기록 지도를 3D 지형으로 돌려 봐요", short: "하루 기록 지도를 3D 지형으로", icon: "cube"),
        Feature(id: "ticket-video", title: "고화질 동영상", detail: "1080p, 워터마크 없이 공유해요", short: "1080p, 워터마크 없이 공유", icon: "video"),
        Feature(id: "ticket-run", title: "하강 상세", detail: "내려오는 모습과 지금 속도·고도를 함께 봐요", short: "속도·고도 그래프와 최고 속도", icon: "chart.xyaxis.line"),
        Feature(id: "ticket-recap", title: "시즌 결산", detail: "이번 시즌을 카드로 정리하고 공유해요", short: "이번 시즌을 카드로 정리하고 공유", icon: "rectangle.on.rectangle"),
    ]
}

/// 미리보기 그림. 캡처가 없으면 시안의 자리 표시를 도형으로 그린다.
private struct FeatureArt: View {
    let feature: Feature

    var body: some View {
        Group {
            // 실제 화면 캡처(3D 보기, 동영상 두 화질, 하강 상세, 결산)를 Assets.xcassets에 feature.id 이름으로 밝게·어둡게 넣으면 자리 표시 대신 쓴다.
            // 세로 전체 화면은 휴대폰 모양으로 가운데에(S18 v6). 동영상은 두 화질 프레임과 라벨을 한 장에 담은 그림이라 테두리 없이 높이에 맞춘다
            if UIImage(named: feature.id) != nil {
                if feature.id == "ticket-video" {
                    Image(feature.id).resizable().scaledToFit().padding(20)
                } else {
                    Image(feature.id).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.cardBorder, lineWidth: 1))
                        .padding(.vertical, 20)
                }
            } else {
                switch feature.id {
                case "ticket-3d": Slope3D()
                case "ticket-video": video
                case "ticket-run": run
                default: recap
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surface)
        .dynamicTypeSize(.large) // 그림 안 글씨는 그림과 함께 고정
        .accessibilityHidden(true)
    }

    private var video: some View {
        HStack(spacing: 25) {
            phone(free: true, label: "무료", quality: "720p")
            phone(free: false, label: "이용권", quality: "1080p")
        }
    }

    private func phone(free: Bool, label: String, quality: String) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottom) {
                Wiggle().stroke(Color.accentFill, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .padding(.vertical, 18).padding(.horizontal, 20)
                if free { Text("SlopeMate").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.primaryText.opacity(0.75)).padding(.bottom, 12) }
            }
            .blur(radius: free ? 1.3 : 0)
            .frame(width: 94, height: 157)
            .background(Color.bg, in: RoundedRectangle(cornerRadius: 14))
            Text("\(label) \(Text(quality).fontWeight(.regular).foregroundStyle(Color.secondaryText))")
                .font(.system(size: 16, weight: .semibold)).monospacedDigit()
        }
    }

    private var run: some View {
        VStack(spacing: 0) {
            Slope3D().frame(height: 128).clipped()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("48\(Text("km/h").font(.system(size: 13, weight: .bold)))").font(.system(size: 30, weight: .bold)).foregroundStyle(Color.accentText)
                    Text("1,139m").font(.system(size: 15, weight: .semibold))
                }
                .monospacedDigit().frame(width: 104, alignment: .leading)
                SpeedGraph()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.card)
            .overlay(alignment: .top) { Color.rowDivider.frame(height: 1) }
        }
    }

    private var recap: some View {
        HStack(spacing: -10) {
            recapCard.environment(\.colorScheme, .dark).rotationEffect(.degrees(-7)).offset(y: 6)
            recapCard.environment(\.colorScheme, .light).rotationEffect(.degrees(6))
        }
    }

    private var recapCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("방문일").font(.system(size: 14, weight: .semibold))
            Text("7\(Text("일").font(.system(size: 22, weight: .heavy)))").font(.system(size: 56, weight: .heavy)).foregroundStyle(Color.accentText)
            Text("84회 · 112km").font(.system(size: 14))
            Spacer(minLength: 0)
            Text("SlopeMate").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.accentText)
        }
        .foregroundStyle(Color.primaryText)
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(width: 134, height: 168, alignment: .leading)
        .background(LinearGradient(colors: [.fadeTop, .bg], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(Color.cardBorder))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 6)
    }
}

/// 3D 지형 위 내 경로 자리 표시 (시안 좌표를 0~1로 옮김)
private struct Slope3D: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { ctx, size in
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }
            func poly(_ pts: [(CGFloat, CGFloat)]) -> Path {
                Path { $0.addLines(pts.map { p($0.0, $0.1) }); $0.closeSubpath() }
            }
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [.fadeTop, .surface]), startPoint: .zero, endPoint: p(0, 1)))
            ctx.fill(poly([(0, 0.25), (0.15, 0.13), (0.31, 0.2), (0.49, 0.06), (0.67, 0.17), (0.85, 0.08), (1, 0.16), (1, 0.62), (0, 0.62)]), with: .color(.cardBorder))
            ctx.fill(poly([(0, 0.58), (0.13, 0.42), (0.28, 0.25), (0.44, 0.03), (0.53, -0.05), (0.62, 0.04), (0.77, 0.25), (0.9, 0.42), (1, 0.52), (1, 1.2), (0, 1.2)]), with: .color(.onAccent.opacity(0.7)))
            ctx.fill(poly([(0, 0.92), (0.21, 0.77), (0.46, 0.84), (0.72, 0.75), (1, 0.86), (1, 1.2), (0, 1.2)]), with: .color(scheme == .dark ? .cardBorder : .secondaryText.opacity(0.6)))
            ctx.fill(poly([(0.44, 0.03), (0.53, -0.05), (0.62, 0.04), (0.58, 0.1), (0.53, 0.04), (0.48, 0.11)]), with: .color(.white.opacity(0.75)))
            var done = Path()
            done.move(to: p(0.526, -0.02))
            done.addCurve(to: p(0.487, 0.54), control1: p(0.564, 0.168), control2: p(0.436, 0.334))
            var rest = Path()
            rest.move(to: p(0.487, 0.54))
            rest.addCurve(to: p(0.436, 1.08), control1: p(0.526, 0.716), control2: p(0.385, 0.873))
            ctx.stroke(rest, with: .color(.accentFill.opacity(0.45)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
            ctx.stroke(done, with: .color(.bg), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            ctx.stroke(done, with: .color(.accentFill), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
            let dot = p(0.487, 0.54)
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 14, y: dot.y - 14, width: 28, height: 28)), with: .color(.accentFill.opacity(0.28)))
            let ring = Path(ellipseIn: CGRect(x: dot.x - 7, y: dot.y - 7, width: 14, height: 14))
            ctx.fill(ring, with: .color(.bg))
            ctx.stroke(ring, with: .color(.accentFill), lineWidth: 3.5)
        }
    }
}

/// 동영상 화면 속 경로 선
private struct Wiggle: Shape {
    func path(in r: CGRect) -> Path {
        Path {
            $0.move(to: CGPoint(x: r.minX + r.width * 0.4, y: r.minY))
            $0.addCurve(to: CGPoint(x: r.minX + r.width * 0.55, y: r.minY + r.height * 0.7),
                        control1: CGPoint(x: r.maxX, y: r.minY + r.height * 0.25),
                        control2: CGPoint(x: r.minX, y: r.minY + r.height * 0.45))
            $0.addQuadCurve(to: CGPoint(x: r.minX + r.width * 0.5, y: r.maxY), control: CGPoint(x: r.maxX * 0.8, y: r.minY + r.height * 0.85))
        }
    }
}

/// 하강 상세의 속도 그래프 자리 표시 (시안 206×64 점)
private struct SpeedGraph: View {
    private static let ys: [CGFloat] = [58, 43.2, 30.1, 21.1, 15.4, 10.4, 8, 12.9, 18.6, 25.2, 40, 58, 58, 58, 41.6, 26.8, 19.5, 17, 21.9, 20.3, 24.4, 33.4, 48.2, 58]
    private static let now = 8

    var body: some View {
        Canvas { ctx, size in
            let pts = Self.ys.indices.map { i in
                CGPoint(x: size.width * CGFloat(i) / CGFloat(Self.ys.count - 1), y: size.height * Self.ys[i] / 64)
            }
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height * 58 / 64)); $0.addLine(to: CGPoint(x: size.width, y: size.height * 58 / 64)) }, with: .color(.rowDivider))
            ctx.stroke(Path { $0.addLines(pts) }, with: .color(.accentText.opacity(0.3)), lineWidth: 2)
            ctx.stroke(Path { $0.addLines(Array(pts[...Self.now])) }, with: .color(.accentText), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            let c = pts[Self.now]
            ctx.stroke(Path { $0.move(to: CGPoint(x: c.x, y: 2)); $0.addLine(to: CGPoint(x: c.x, y: size.height * 58 / 64)) }, with: .color(.primaryText.opacity(0.45)))
            let ring = Path(ellipseIn: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
            ctx.fill(ring, with: .color(.card))
            ctx.stroke(ring, with: .color(.accentText), lineWidth: 2.5)
        }
        .frame(height: 64)
    }
}

#Preview("구입 전") {
    SeasonTicketView().environment(SeasonTicket())
}

#Preview("결제 대기") {
    let t = SeasonTicket()
    t.status = .pending
    return SeasonTicketView().environment(t)
}
