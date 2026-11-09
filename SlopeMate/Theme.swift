import SwiftUI
import UIKit

/// 디자인 시스템 색 (07-visual-design 2장). 밝게·어둡게 한 쌍.
extension Color {
    static let bg = Color(light: 0xF6FAFB, dark: 0x0B161B)            // 60 바탕
    static let surface = Color(light: 0xDDEFF2, dark: 0x14303A)       // 30 카드·보조 면
    static let accentFill = Color(light: 0x0E9AA7, dark: 0x5CE1E6)    // 10 강조 면
    static let accentText = Color(light: 0x087480, dark: 0x5CE1E6)    // 10 강조 글씨·숫자
    static let secondaryText = Color(light: 0x4A636C, dark: 0x86A0A8) // 보조 글씨
    static let primaryText = Color(light: 0x111418, dark: 0xF4F8FA)
    static let stopRed = Color(light: 0xD93A3A, dark: 0xFF6B6B)
    /// 카드 면과 테두리 (확정 시안 값: 밝게 흰 카드, 어둡게 #18252B)
    static let card = Color(light: 0xFFFFFF, dark: 0x18252B)
    static let cardBorder = Color(light: 0xC9D9DE, dark: 0x23404B)
    /// 강조 면 위 글씨
    static let onAccent = Color(light: 0x111418, dark: 0x0B161B)
    /// 세 탭 첫 화면 위쪽 페이드 시작색
    static let fadeTop = Color(light: 0xCDEAF0, dark: 0x153A43)
    /// 기록 중 화면 위쪽 페이드 시작색
    static let fadeTopRecording = Color(light: 0xB9E6EC, dark: 0x123139)

    init(light: UInt32, dark: UInt32) {
        func ui(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

/// 세 탭 첫 화면과 기록 중 화면의 배경: 위에서 하늘색으로 시작해 아래로 바탕색이 된다. 그 밖의 화면은 단색 `Color.bg`.
struct FadeBackground: View {
    var recording = false
    var body: some View {
        LinearGradient(stops: [.init(color: recording ? .fadeTopRecording : .fadeTop, location: 0), .init(color: .bg, location: 0.45)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

// MARK: 공통 부품 (07-visual-design 4장)

extension View {
    /// 요약 카드: 흰(어둡게 짙은) 면, 옅은 테두리, 둥근 모서리 24
    func card(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.cardBorder))
    }
}

/// 큰 버튼: 화면 폭, 60pt 이상, 강조 면. 기록 시작·종료 같은 화면의 주요 동작 하나에만.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .foregroundStyle(Color.onAccent)
            .multilineTextAlignment(.center)
            // 큰 글씨에서는 두 줄까지 쓰고 그래도 넘치면 조금 줄인다(버튼 밖으로 넘치지 않게)
            .lineLimit(2).minimumScaleFactor(0.6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding(.horizontal, 20)
            .background(Color.accentFill.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 24))
    }
}

/// 카드 머리의 둥근 아이콘 (48pt, 보조 면)
struct IconCircle: View {
    var systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.title3)
            .foregroundStyle(Color.accentText)
            .frame(width: 48, height: 48)
            .background(Color.surface, in: Circle())
            .accessibilityHidden(true)
    }
}
