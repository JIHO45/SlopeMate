import SwiftUI

/// 슬로프 이름 말풍선 v1 (R50, R9, K): 난이도 색 점 8pt + 이름(없으면 "이름 정보 없음", 면은 "슬로프 구역") + " · 난이도". 꼬리 없는 알약.
/// 자리(누른 선 위 12pt, 좌우 16pt 안)는 DayMapView가 정한다
struct SlopeBalloon: View {
    let hit: SlopePick.Hit
    @Environment(\.colorScheme) private var scheme

    private var name: String { hit.name ?? (hit.area ? "슬로프 구역" : "이름 정보 없음") }
    private var level: String? { SlopeStyle.label(SlopeStyle.level(hit.difficulty)) }

    var body: some View {
        let dark = scheme == .dark
        let casing = SlopeStyle.casing(SlopeStyle.level(hit.difficulty), dark: dark)
        HStack(spacing: 6) {
            Circle()
                .fill(Color(SlopeStyle.color(difficulty: hit.difficulty, dark: dark)))
                .overlay { if let casing { Circle().strokeBorder(Color(light: casing, dark: casing), lineWidth: 1) } }
                .frame(width: 8, height: 8)
            Text(name).font(.footnote.weight(.bold)).foregroundStyle(Color.primaryText)
                + Text(level.map { " · \($0)" } ?? "").font(.footnote).foregroundStyle(Color.secondaryText)
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.map { "\(name), \($0)" } ?? name)
    }
}

