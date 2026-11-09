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
