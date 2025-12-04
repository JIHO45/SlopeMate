import SwiftUI

struct WeatherIconView: View {
    let weather: WeatherDisplayModel?
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    init(weather: WeatherDisplayModel?, size: CGFloat = 80) {
        self.weather = weather
        self.size = size
    }
    
    // 기존 호환성을 위한 초기화
    init(iconURL: URL?, size: CGFloat = 80) {
        self.weather = nil
        self.size = size
    }

    var body: some View {
        Group {
            if let weather {
                Image(systemName: weather.systemIconName)
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "cloud.sun.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
    }
}

#if DEBUG
#Preview("Weather Icon") {
    WeatherIconView(weather: .preview)
        .padding()
        .background(Color(.systemBackground))
}
#endif

