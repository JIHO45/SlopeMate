import SwiftUI
import WidgetKit

/// 위젯 확장: 기록 상태 Live Activity만 둔다 (R23). 홈 화면 위젯·컨트롤은 기획에 없다.
@main
struct SlopeMateWidgetBundle: WidgetBundle {
    var body: some Widget {
        SlopeMateWidgetLiveActivity()
    }
}
