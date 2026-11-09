import SwiftUI

/// 날씨 상세 (R33, R39, 확정 시안 v1). 홈의 날씨 카드에서 들어온다.
struct WeatherDetailView: View {
    let cache: WeatherCache
    let homes: [String]
    @State var selected: String
    @State private var weather: WeatherLoad = .loading
    @State private var retry = 0
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .largeTitle) private var nowSize = 56

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if homes.count > 1 {
                    Picker("리조트", selection: $selected) {
                        ForEach(homes, id: \.self) { Text(Resort.name($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text(Resort.name(selected)).font(.headline).frame(maxWidth: .infinity)
                }
                switch weather {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                case .failed:
                    VStack(spacing: 12) {
                        Text("날씨를 불러오지 못했어요").font(.headline)
                        Button("다시 시도", systemImage: "arrow.clockwise") { retry += 1 }.buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                case .loaded(let s):
                    content(s)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .background(Color.bg)
        .navigationTitle("날씨")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(selected)-\(retry)") {
            guard let resort = Resort.all.first(where: { $0.id == selected }) else { return }
            weather = .loading
            do { weather = .loaded(try await cache.weather(for: resort)) } catch { weather = .failed }
        }
    }

    @ViewBuilder private func content(_ s: WeatherSnapshot) -> some View {
        let today = s.days.first
        HStack(spacing: 12) {
            Text(WeatherFormat.temp(s.current.temperature))
                .font(.system(size: nowSize, weight: .bold)).monospacedDigit()
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Label(s.current.condition, systemImage: s.current.symbolName).font(.headline)
                if let today {
                    Text("최고 \(WeatherFormat.temp(today.high)) · 최저 \(WeatherFormat.temp(today.low))")
                }
                Text("바람 \(Int(s.current.windSpeed.rounded()))m/s")
            }
            .font(.subheadline).monospacedDigit().foregroundStyle(Color.secondaryText)
        }
        .foregroundStyle(Color.primaryText)
        .padding(.horizontal, 4).frame(minHeight: 72)

        if let est = SnowForecast.estimate(hours: s.hours, now: .now) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) { Text("예상 설질"); ForecastTag() }
                    .font(.subheadline).foregroundStyle(Color.secondaryText)
                Text(est.level.label).font(.title2.bold())
                Text(est.reason).font(.subheadline).foregroundStyle(Color.secondaryText)
            }
            .padding(.vertical, 12).padding(.horizontal, 16)
            .detailCard()
            .accessibilityElement(children: .combine)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("시간대별").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(s.next24h(now: .now).enumerated()), id: \.offset) { i, h in
                        VStack(spacing: 6) {
                            Text(i == 0 ? "지금" : "\(HomeData.seoul.component(.hour, from: h.date))시")
                                .fontWeight(i == 0 ? .semibold : .regular)
                                .foregroundStyle(i == 0 ? Color.primaryText : Color.secondaryText)
                            Image(systemName: h.symbolName).symbolRenderingMode(.multicolor).frame(height: 24)
                            Text(WeatherFormat.temp(h.temperature)).fontWeight(.semibold).monospacedDigit()
                        }
                        .font(.subheadline)
                        .frame(width: 48)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.trailing, 16)
            }
        }
        .padding(.vertical, 12).padding(.leading, 16)
        .detailCard()

        VStack(alignment: .leading, spacing: 4) {
            Text("7일").font(.subheadline.weight(.semibold))
            let lo = s.days.map(\.low).min() ?? 0, hi = s.days.map(\.high).max() ?? 1
            ForEach(Array(s.days.enumerated()), id: \.offset) { i, d in
                HStack(spacing: 8) {
                    Text(i == 0 ? "오늘" : d.date.formatted(Date.FormatStyle(locale: Locale(identifier: "ko_KR"), timeZone: HomeData.seoul.timeZone).weekday(.abbreviated)))
                        .fontWeight(i == 0 ? .semibold : .regular).frame(width: 40, alignment: .leading)
                    Image(systemName: d.symbolName).symbolRenderingMode(.multicolor).frame(width: 24)
                    Text(d.precipitationChance >= 0.1 ? "\(Int((d.precipitationChance * 10).rounded()) * 10)%" : "")
                        .font(.footnote).foregroundStyle(Color.accentText).frame(width: 40, alignment: .leading)
                    Text(WeatherFormat.temp(d.low)).foregroundStyle(Color.secondaryText).frame(width: 36, alignment: .trailing)
                    TempBar(from: (d.low - lo) / max(hi - lo, 1), to: (d.high - lo) / max(hi - lo, 1))
                    Text(WeatherFormat.temp(d.high)).frame(width: 36, alignment: .trailing)
                }
                .font(.subheadline).monospacedDigit()
                .frame(minHeight: 34)
                .accessibilityElement(children: .combine)
                if i < s.days.count - 1 { Divider() }
            }
        }
        .padding(.top, 12).padding(.horizontal, 16).padding(.bottom, 4)
        .detailCard()

        // 출처 표시는 생략하지 않는다 (07-visual-design 8장)
        HStack {
            AsyncImage(url: scheme == .dark ? s.attribution.markDarkURL : s.attribution.markLightURL) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                Text("Apple Weather").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
            }
            .frame(height: 20)
            .accessibilityLabel("Apple Weather")
            Spacer()
            Link("데이터 출처", destination: s.attribution.legalPageURL)
                .font(.subheadline).tint(Color.accentText).frame(minHeight: 44)
        }
        .padding(.horizontal, 4)
    }
}

/// 날씨 조회 상태 (홈 카드와 상세가 함께 씀)
enum WeatherLoad {
    case loading, failed
    case loaded(WeatherSnapshot)
}

nonisolated enum WeatherFormat {
    static func temp(_ c: Double) -> String { "\(Int(c.rounded()))°" }
}

/// 예상 설질 표시: 테두리만 있는 작은 태그 (R39, 사용자 평가의 채운 모양과 구분)
struct ForecastTag: View {
    var body: some View {
        Text("예상").font(.caption).foregroundStyle(Color.accentText)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentText))
    }
}

private struct TempBar: View {
    var from: Double
    var to: Double
    var body: some View {
        GeometryReader { g in
            Capsule().fill(Color.primaryText.opacity(0.07))
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.accentFill)
                        .frame(width: max(6, g.size.width * (to - from)))
                        .offset(x: g.size.width * from)
                }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

private extension View {
    func detailCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
    }
}
