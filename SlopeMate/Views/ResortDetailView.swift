import SwiftUI

struct ResortDetailView: View {
    let resort: Resort
    let weather: WeatherDisplayModel?

    @State private var activeSheet: DetailSheet?

    private let metricColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                weatherSection
                actionButtons
                Spacer(minLength: 16)
            }
            .padding()
        }
        .navigationTitle(resort.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet) { sheet in
            SafariView(url: sheet.url)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Label("운영 시간", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(resort.operatingHours.detailText)
                    .font(.footnote)
            }
            
            Label("운영 슬로프 및 리프트는 기상 상황에 따라 변경될 수 있습니다.", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.top, 4)
        }
    }

    private var weatherSection: some View {
        Group {
            if let weather {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(weather.description.capitalized)
                                .font(.title3)
                            Text("\(weather.temperature.formatted(.number.precision(.fractionLength(1))))°C")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(weather.iconColor)
                            Text("체감 \(weather.feelsLike.formatted(.number.precision(.fractionLength(1))))°C")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        WeatherIconView(weather: weather)
                    }

                    LazyVGrid(columns: metricColumns, spacing: 12) {
                        WeatherMetricView(
                            title: "습도",
                            value: "\(weather.humidity)%",
                            icon: "drop.fill"
                        )
                        WeatherMetricView(
                            title: "풍속",
                            value: "\(weather.windSpeed.formatted(.number.precision(.fractionLength(1)))) m/s",
                            icon: "wind",
                            isStrongWind: weather.windSpeed >= 10
                        )
                        WeatherMetricView(
                            title: "일출",
                            value: weather.sunrise.formattedTime(),
                            icon: "sunrise.fill"
                        )
                        WeatherMetricView(
                            title: "일몰",
                            value: weather.sunset.formattedTime(),
                            icon: "sunset.fill"
                        )
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("날씨 정보를 불러오지 못했습니다.")
                        .font(.headline)
                    Text("인터넷 연결을 확인하거나 화면을 아래로 당겨 새로고침하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if let slopeURL = URL(string: resort.slopeStatusURL) {
                Button {
                    activeSheet = .slope(slopeURL)
                } label: {
                    Label(
                        resort.webCamURL == nil ? "실시간 슬로프 현황 및 웹캠 보기" : "실시간 슬로프 현황 보기",
                        systemImage: "mountain.2.circle.fill"
                    )
                }
                .buttonStyle(ResortActionButtonStyle())
            }

            if let webCamURL = resort.webCamURL, let url = URL(string: webCamURL) {
                Button {
                    activeSheet = .webcam(url)
                } label: {
                    Label("실시간 웹캠 보기", systemImage: "video.circle.fill")
                }
                .buttonStyle(ResortActionButtonStyle(tint: .teal))
            }
        }
    }
}

private enum DetailSheet: Identifiable {
    case slope(URL)
    case webcam(URL)

    var id: String {
        switch self {
        case .slope(let url):
            return "slope-\(url.absoluteString)"
        case .webcam(let url):
            return "webcam-\(url.absoluteString)"
        }
    }

    var url: URL {
        switch self {
        case .slope(let url), .webcam(let url):
            return url
        }
    }
}

private struct WeatherMetricView: View {
    let title: String
    let value: String
    let icon: String
    var isStrongWind: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(isStrongWind ? .orange : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemBackground).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct DisabledActionLabel: View {
    let title: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(title)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
                .foregroundStyle(.secondary)
        )
    }
}

private struct ResortActionButtonStyle: ButtonStyle {
    var tint: Color = .blue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(tint.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: tint.opacity(0.3), radius: 8, y: 4)
    }
}

private extension Date {
    func formattedTime() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        return formatter.string(from: self)
    }
}

#if DEBUG
#Preview("리조트 상세") {
    NavigationStack {
        ResortDetailView(
            resort: Resort(
                name: "하이원 리조트",
                latitude: 37.2067,
                longitude: 128.8390,
                homePageURL: "https://www.high1.com",
                slopeStatusURL: "https://www.high1.com/www/slopeView.do?key=676",
                webCamURL: "https://www.high1.com/www/webCamView.do?key=674",
                operatingHours: .simple("09:00 - 16:00")
            ),
            weather: .preview
        )
    }
}

#Preview("리조트 상세 - 날씨 없음") {
    NavigationStack {
        ResortDetailView(
            resort: Resort(
                name: "하이원 리조트",
                latitude: 37.2067,
                longitude: 128.8390,
                homePageURL: "https://www.high1.com",
                slopeStatusURL: "https://www.high1.com/www/slopeView.do?key=676",
                webCamURL: "https://www.high1.com/www/webCamView.do?key=674",
                operatingHours: .simple("09:00 - 16:00")
            ),
            weather: nil
        )
    }
}
#endif

