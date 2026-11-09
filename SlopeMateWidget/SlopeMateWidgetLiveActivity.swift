import ActivityKit
import SwiftUI
import WidgetKit

/// 기록 상태 Live Activity (R23, 07-visual-design Live Activity v2 숫자 라벨 있음). 어두운 배경 기준, 버튼 없음.
/// 상태: 기록 중 · 기록 멈춤 · 8시간 뒤(갱신 끝) · 종료(하루 합계).
struct SlopeMateWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(context: context)
                .padding(16)
                .activityBackgroundTint(LA.bg)
                .activitySystemActionForegroundColor(LA.text)
                .widgetURL(RecordingActivityAttributes.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.resortName).font(.subheadline.weight(.semibold)).foregroundStyle(LA.text)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusLabel(context: context).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let reason = context.state.stopped {
                        Text(reason).font(.footnote).foregroundStyle(LA.secondary)
                    } else {
                        Numbers(state: context.state, live: !context.isStale)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.stopped == nil ? "figure.skiing.downhill" : "stop.fill")
                    .foregroundStyle(context.state.stopped == nil ? LA.accent : LA.red)
            } compactTrailing: {
                Text("\(context.state.runs)회").monospacedDigit().foregroundStyle(LA.accent)
            } minimal: {
                Text("\(context.state.runs)").monospacedDigit().foregroundStyle(LA.accent)
            }
            .widgetURL(RecordingActivityAttributes.url)
            .keylineTint(LA.accent)
        }
    }
}

/// 시안 색 (어두운 배경 기준)
private enum LA {
    static let bg = Color(red: 0x10 / 255, green: 0x15 / 255, blue: 0x1C / 255)
    static let text = Color(red: 0xF4 / 255, green: 0xF8 / 255, blue: 0xFA / 255)
    static let secondary = Color(red: 0xC9 / 255, green: 0xD1 / 255, blue: 0xDA / 255)
    static let label = Color(red: 0x86 / 255, green: 0xA0 / 255, blue: 0xA8 / 255)
    static let accent = Color(red: 0x5C / 255, green: 0xE1 / 255, blue: 0xE6 / 255)
    static let red = Color(red: 0xFF / 255, green: 0xB4 / 255, blue: 0xB4 / 255)

    static func km(_ m: Double) -> String { String(format: "%.1f", m / 1000) }
}

private struct StatusLabel: View {
    let context: ActivityViewContext<RecordingActivityAttributes>
    var body: some View {
        if context.state.stopped != nil {
            Label("기록 멈춤", systemImage: "stop.fill").font(.subheadline.weight(.heavy)).foregroundStyle(LA.red)
        } else if context.state.ended {
            Text("기록 끝").font(.subheadline.weight(.semibold)).foregroundStyle(LA.secondary)
        } else {
            HStack(spacing: 6) {
                Circle().fill(LA.accent).frame(width: 7, height: 7)
                Text("기록 중").font(.subheadline.weight(.semibold)).foregroundStyle(LA.accent)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        let s = context.state
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(context.attributes.resortName).font(.subheadline.weight(.semibold)).foregroundStyle(LA.text)
                Text("|").foregroundStyle(LA.label)
                StatusLabel(context: context)
                Spacer()
            }
            if let reason = s.stopped {
                Text(reason).font(.subheadline).foregroundStyle(LA.text)
                Text("멈추기 전까지 \(s.runs)회 · \(LA.km(s.distance))km").font(.footnote).foregroundStyle(LA.secondary)
            } else if context.isStale && !s.ended {
                // 8시간 뒤: 갱신이 끝났다. 기록은 계속된다.
                Text("앱을 열면 다시 표시돼요").font(.subheadline).foregroundStyle(LA.secondary)
            } else {
                Numbers(state: s, live: true)
            }
        }
    }
}

/// 숫자 줄: 경과 · 하강(강조색) · 거리, 아래에 라벨
private struct Numbers: View {
    let state: RecordingActivityAttributes.ContentState
    /// 기록 중이면 경과 시간이 흐른다
    let live: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            cell(label: "경과") {
                if let end = state.endedAt {
                    // 끝낸 기록: 경과 시간을 고정
                    Text(Duration.seconds(max(0, end.timeIntervalSince(state.startedAt))).formatted(.time(pattern: .hourMinuteSecond)))
                } else if live {
                    Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                } else {
                    Text("–")
                }
            }
            cell(label: "하강") { Text("\(state.runs)").foregroundStyle(LA.accent) }
            cell(label: "거리") {
                Text(LA.km(state.distance)) + Text("km").font(.footnote.weight(.semibold))
            }
        }
    }

    private func cell(label: String, @ViewBuilder _ value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            value().font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(LA.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(LA.label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("기록 중", as: .content, using: RecordingActivityAttributes(recordingId: "preview", resortName: "하이원", shownAt: .now)) {
    SlopeMateWidgetLiveActivity()
} contentStates: {
    RecordingActivityAttributes.ContentState(startedAt: .now - 8048, runs: 12, distance: 18_400)
    RecordingActivityAttributes.ContentState(startedAt: .now - 8048, runs: 12, distance: 18_400, stopped: "위치 권한이 꺼졌어요. 앱을 열어 다시 켜 주세요")
    RecordingActivityAttributes.ContentState(startedAt: .now - 8048, runs: 12, distance: 18_400, ended: true, endedAt: .now)
}
