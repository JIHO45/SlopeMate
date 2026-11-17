import SwiftUI
import StoreKit

/// S20 시즌 결산 (R53; 07-visual-design 6장 C 확정 S20 v3, 카드 밝게 v1·어둡게 v2, 이용권 없음 안내 카드는 S20 v1 내용).
/// 4:5 카드를 옆으로 넘긴다. 카드 색은 화면 모드를 따르다가 바꾸면 기억하고 공유 이미지에도 쓴다.
struct SeasonRecapView: View {
    let days: [Stats.Day]
    let season: String
    let passes: [(pass: SeasonPass, resorts: [String])]

    @Environment(SeasonTicket.self) private var ticket
    @Environment(\.colorScheme) private var scheme
    /// "" 화면 모드를 따름, "light", "dark"
    @AppStorage("recapCardColor") private var cardColor = ""
    @State private var page: Int? = 0
    @State private var showTicket = false
    @Environment(\.dynamicTypeSize) private var typeSize

    /// S9와 S20이 같은 카드를 센다(세션은 시간표, 슬로프는 이름이 켜진 리조트만)
    static func cards(days: [Stats.Day], season: String, passes: [(pass: SeasonPass, resorts: [String])]) -> [SeasonRecap.Card] {
        SeasonRecap.cards(days: days, season: season, passes: passes,
                          session: { RecordFormat.session($0, resortId: $1) },
                          slopeName: { r, id in SlopeNames.isShown(r) ? SlopeMap.cached(resortId: r)?.slopes.first { $0.id == id }?.name : nil })
    }

    private var dark: Bool { cardColor.isEmpty ? scheme == .dark : cardColor == "dark" }

    var body: some View {
        let cards = Self.cards(days: days, season: season, passes: passes)
        let final = SeasonRecap.isFinal(season: season)
        let header = "\(season) 시즌 · \(final ? "최종 결산" : "지금까지")"
        let lock = SeasonRecap.lock(season: season, owned: ticket.seasons, current: SeasonTicket.season(purchase: .now))
        let shown = lock == .open ? cards : Array(cards.prefix(1))
        let locked = Array(cards.dropFirst(shown.count))
        let pages = shown.count + (locked.isEmpty ? 0 : 1)
        let i = max(0, min(page ?? 0, pages - 1))
        let onLock = !locked.isEmpty && i >= shown.count
        // 가장 큰 글씨에서는 아래 고정을 버튼만 두고 안내 줄은 스크롤 내용 끝으로 옮긴다
        let ax = typeSize.isAccessibilitySize
        let note = Text(onLock ? (lock == .pastSeason ? SeasonRecap.pastSeasonNote : ticketLine) : "GPS 좌표와 경로는 이미지에 넣지 않아요")
            .font(.footnote).foregroundStyle(Color.secondaryText).monospacedDigit()
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            .padding(.horizontal, 20).padding(.bottom, 12)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(final ? "최종 결산" : "지금까지").font(.title.bold())
                    Text(final ? "\(season) 시즌" : "\(season) 시즌 · 4월 30일이 지나면 최종 결산")
                        .font(.subheadline).foregroundStyle(Color.secondaryText)
                }
                .padding(.horizontal, 20).padding(.top, 8)

                colorPicker.padding(.horizontal, 16).padding(.top, 16)

                if pages == 0 {
                    Text("이번 시즌 기록이 생기면 결산 카드를 만들어요")
                        .font(.body).foregroundStyle(Color.secondaryText)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        .padding(.horizontal, 20).padding(.top, 40)
                } else {
                    GeometryReader { g in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 12) {
                                ForEach(shown.indices, id: \.self) { n in
                                    RecapCardView(card: shown[n], header: header, dark: dark).id(n)
                                        .accessibilityValue("\(n + 1)번째, 총 \(pages)장")
                                }
                                if !locked.isEmpty {
                                    lockCard(locked, past: lock == .pastSeason).id(shown.count)
                                        .accessibilityValue("\(pages)번째, 총 \(pages)장")
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .contentMargins(.horizontal, max(16, (g.size.width - 320) / 2), for: .scrollContent)
                        .scrollTargetBehavior(.viewAligned)
                        .scrollPosition(id: $page)
                        .scrollIndicators(.hidden)
                    }
                    .frame(height: 400).padding(.top, 18)

                    HStack(spacing: 8) {
                        ForEach(0..<pages, id: \.self) { n in
                            Circle().fill(n == i ? Color.accentFill : Color.cardBorder).frame(width: 7, height: 7)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .accessibilityHidden(true)
                }
                if ax { note }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !ax { note }
                Group {
                    if onLock {
                        // 지난 시즌 이용권은 팔지 않으므로 S18을 열지 않고 위 안내만 둔다
                        if lock == .ticket { Button("시즌 이용권 보기") { showTicket = true } }
                    } else {
                        Button("이 카드 공유") { if shown.indices.contains(i) { share(shown[i], header: header) } }
                            .disabled(shown.isEmpty)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .padding(.top, 12)
            .background(Color.bg)
        }
        .foregroundStyle(Color.primaryText)
        .background(Color.bg.ignoresSafeArea())
        .navigationTitle("시즌 결산")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTicket) { SeasonTicketView() }
    }

    // MARK: 카드 색

    private var colorPicker: some View {
        // 가장 큰 글씨에서는 "카드 색"과 버튼 둘을 세로로 쌓는다
        let stack = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return stack {
            Text("카드 색").font(.subheadline.weight(.semibold)).padding(.leading, 4).padding(.trailing, 6)
            colorButton("밝게", swatch: 0xCFE8F0, edge: 0xC9D9DE, on: !dark) { cardColor = "light" }
            colorButton("어둡게", swatch: 0x0B161B, edge: 0x23404B, on: dark) { cardColor = "dark" }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("카드 색")
    }

    private func colorButton(_ title: String, swatch: UInt32, edge: UInt32, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6).fill(Color(light: swatch, dark: swatch))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(light: edge, dark: edge)))
                    .frame(width: 20, height: 20).accessibilityHidden(true)
                Text(title).fontWeight(on ? .bold : .regular)
                if on { Image(systemName: "checkmark").font(.footnote.weight(.heavy)).foregroundStyle(Color.accentText).accessibilityHidden(true) }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.card, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.accentText : Color.cardBorder, lineWidth: on ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: 이용권 없음

    private func lockCard(_ locked: [SeasonRecap.Card], past: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            IconCircle(systemName: "lock")
            Text("나머지 카드 \(locked.count)장").font(.system(size: 22, weight: .bold)).padding(.top, 14)
            Text(past ? SeasonRecap.pastSeasonNote : "시즌 이용권으로 열어요").font(.system(size: 15)).foregroundStyle(Color.secondaryText)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(locked.indices, id: \.self) { n in
                    HStack(spacing: 8) {
                        Image(systemName: "lock").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.secondaryText)
                        Text(locked[n].lockedName)
                    }
                    .font(.system(size: 15)).frame(height: 26)
                }
            }
            .padding(.top, 16)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 28, leading: 26, bottom: 24, trailing: 26))
        .frame(width: 320, height: 400, alignment: .topLeading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.cardBorder))
        .accessibilityElement(children: .combine)
    }

    private var ticketLine: String {
        let until = SeasonTicketView.untilText(SeasonTicket.expiry(purchase: .now))
        return ((ticket.product.map { [SeasonTicketView.priceText($0)] } ?? []) + [until, "자동 갱신 없음"]).joined(separator: " · ")
    }

    // MARK: 공유

    /// 1080×1350. 요약 숫자만 새로 그리므로 지도·경로·좌표와 위치 메타데이터가 들어가지 않는다(R31과 같음)
    private func share(_ card: SeasonRecap.Card, header: String) {
        let r = ImageRenderer(content: RecapCardView(card: card, header: header, dark: dark, rounded: false).dynamicTypeSize(.large))
        r.scale = 1080.0 / 320
        guard let image = r.uiImage else { return }
        ShareSheet.present([image])
    }
}

/// 결산 카드 한 장, 320×400pt. 글자 크기는 이미지 안에서 고정이라 Dynamic Type을 따르지 않는다(공유 이미지와 같음)
struct RecapCardView: View {
    let card: SeasonRecap.Card
    let header: String
    let dark: Bool
    var rounded = true

    private struct Palette {
        var top: UInt32, bottom: UInt32, stop: Double, border: UInt32, text: UInt32, secondary: UInt32, accent: UInt32
        var bars: [UInt32]  // 주간·야간·심야
    }
    private static let light = Palette(top: 0xCFE8F0, bottom: 0xF6FAFB, stop: 0.58, border: 0xC9D9DE, text: 0x111418,
                                       secondary: 0x4A636C, accent: 0x087480, bars: [0x0E9AA7, 0x087480, 0x111418])
    private static let darkP = Palette(top: 0x153A43, bottom: 0x0B161B, stop: 0.62, border: 0x23404B, text: 0xF4F8FA,
                                       secondary: 0xA3BCC3, accent: 0x5CE1E6, bars: [0x1E8F99, 0x5CE1E6, 0xF4F8FA])
    private var p: Palette { dark ? Self.darkP : Self.light }
    private func c(_ v: UInt32) -> Color { Color(light: v, dark: v) }

    private static let dayFormat: DateFormatter = {
        let d = DateFormatter()
        d.locale = Locale(identifier: "ko_KR")
        d.timeZone = TimeZone(identifier: "Asia/Seoul")
        d.dateFormat = "M월 d일 EEEE"
        return d
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(header).font(.system(size: 13, weight: .semibold)).foregroundStyle(c(p.secondary))
            Text(title).font(.system(size: 22, weight: .bold)).padding(.top, 14)
            content
            Spacer(minLength: 0)
            Text("SlopeMate").font(.system(size: 15, weight: .bold)).foregroundStyle(c(p.accent))
        }
        .foregroundStyle(c(p.text))
        .lineLimit(1).minimumScaleFactor(0.5)
        .padding(EdgeInsets(top: 28, leading: 26, bottom: 24, trailing: 26))
        .frame(width: 320, height: 400, alignment: .topLeading)
        .background(LinearGradient(stops: [.init(color: c(p.top), location: 0), .init(color: c(p.bottom), location: p.stop)],
                                   startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: rounded ? 28 : 0))
        .overlay { if rounded { RoundedRectangle(cornerRadius: 28).strokeBorder(c(p.border)) } }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch card {
        case .sessions: "세션"
        default: card.lockedName
        }
    }

    @ViewBuilder private var content: some View {
        switch card {
        case let .totals(visitDays, runs, distance):
            big("\(visitDays)", "일", 96, 32)
            HStack(spacing: 28) {
                stat("\(runs)", "회", "하강")
                stat(String(RecordFormat.km(distance).dropLast(2)), "km", "거리")
            }
            .padding(.top, 20)
        case let .drop(total, perDay):
            big(Self.m(total), "m", 60, 28)
            lines(nil, "하루 평균 \(Self.m(perDay))m", secondaryFirst: "내려온 높이를 모두 더했어요")
        case let .sessions(shares):
            let top = shares.max { $0.percent < $1.percent }!
            big("\(RecordFormat.sessionName(top.kind)) \(top.percent)", "%", 52, 28)
            GeometryReader { g in
                let w = g.size.width - 3 * Double(shares.count - 1)
                HStack(spacing: 3) {
                    ForEach(shares.indices, id: \.self) { n in
                        RoundedRectangle(cornerRadius: 6).fill(bar(shares[n].kind)).frame(width: w * Double(shares[n].percent) / 100)
                    }
                }
            }
            .frame(height: 20).padding(.top, 18).padding(.bottom, 12)
            ForEach(shares.indices, id: \.self) { n in
                let s = shares[n]
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(bar(s.kind)).frame(width: 12, height: 12)
                    Text(RecordFormat.sessionName(s.kind)).fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Text("\(s.runs)회").foregroundStyle(c(p.secondary))
                    Text("\(s.percent)%").fontWeight(.semibold).frame(width: 48, alignment: .trailing)
                }
                .font(.system(size: 17)).monospacedDigit().frame(height: 26)
            }
        case let .topResort(resortId, days, of, runs, distance):
            big(Resort.name(resortId), "", 64, 1)
            lines("\(of)일 중 \(days)일", "\(runs)회 · \(RecordFormat.km(distance))")
        case let .topDay(date, resortId, runs, distance, drop):
            big("\(runs)", "회", 80, 32)
            lines("\(Self.dayFormat.string(from: date)) · \(Resort.name(resortId))", "\(RecordFormat.km(distance)) · 고도차 \(Self.m(drop))m")
        case let .topSlope(name, resortId, runs):
            big(name, "", 56, 1)
            lines("\(runs)회", Resort.name(resortId))
        case let .pass(name, visits, perVisit, ticket):
            big(perVisit.formatted(), "원", 56, 28)
            lines("\(name) · 1회 방문당", "\(visits)일 · 리프트권이었다면 \(RecordFormat.won(ticket))")
        }
    }

    private static func m(_ v: Double) -> String { Int(v.rounded()).formatted() }

    private func bar(_ k: SessionKind) -> Color {
        c(p.bars[k == .day ? 0 : k == .night ? 1 : 2])
    }

    private func big(_ value: String, _ unit: String, _ size: CGFloat, _ unitSize: CGFloat) -> some View {
        (Text(value).font(.system(size: size, weight: .heavy)).tracking(-1)
            + Text(unit).font(.system(size: unitSize, weight: .heavy)))
            .foregroundStyle(c(p.accent)).monospacedDigit()
            .padding(.top, 10)
    }

    private func stat(_ value: String, _ unit: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text(value).font(.system(size: 32, weight: .bold)) + Text(unit).font(.system(size: 18, weight: .bold))).monospacedDigit()
            Text(label).font(.system(size: 15)).foregroundStyle(c(p.secondary))
        }
    }

    /// 굵은 줄 다음 보조 줄. 고도차 카드만 보조 줄이 먼저
    private func lines(_ strong: String?, _ second: String, secondaryFirst: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let secondaryFirst {
                Text(secondaryFirst).foregroundStyle(c(p.secondary))
                Text(second).fontWeight(.semibold)
            } else {
                if let strong { Text(strong).fontWeight(.semibold) }
                Text(second).foregroundStyle(c(p.secondary))
            }
        }
        .font(.system(size: 17)).monospacedDigit()
        .padding(.top, 8)
    }
}

#Preview("결산 카드 · 밝게·어둡게") {
    let day = Date(timeIntervalSince1970: 1_796_000_000)
    ScrollView(.horizontal) {
        HStack {
            ForEach([false, true], id: \.self) { d in
                RecapCardView(card: .totals(visitDays: 7, runs: 84, distance: 112_000), header: "2026-27 시즌 · 지금까지", dark: d)
                RecapCardView(card: .sessions([.init(kind: .day, runs: 52, percent: 62), .init(kind: .night, runs: 25, percent: 30),
                                               .init(kind: .lateNight, runs: 7, percent: 8)]), header: "2026-27 시즌 · 지금까지", dark: d)
                RecapCardView(card: .topDay(date: day, resortId: "high1", runs: 24, distance: 31_200, drop: 4120), header: "2026-27 시즌 · 지금까지", dark: d)
            }
        }
    }
}
