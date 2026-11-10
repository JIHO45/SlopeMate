import SwiftUI

/// B1 틀: 탭 기록·시즌·크루와 기록 중 막대 (07-visual-design 6장 B1, decisions 2026-11-09).
struct RootView: View {
    @Bindable var recorder: Recorder
    var account: Account
    var crews: Crews
    var summary: SummarySync
    var deletion: AccountDeletion
    @Environment(\.scenePhase) private var phase
    @State private var showRecording = false
    @State private var tab = Tab.record
    /// S1: 첫 실행에 한 번
    @State private var setup = !Settings.homeSetupDone

    enum Tab { case record, season, crew }

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                tabs.recordingAccessory(recorder.recording != nil) { RecordingBar(recorder: recorder) { tab = .record; showRecording = true } }
            } else {
                tabs
            }
        }
        .fullScreenCover(isPresented: $setup) { HomeSetupView(db: recorder.db) { setup = false } }
        // 시즌 합계를 크루 순위로(R15): 크루가 생기거나 바뀔 때, 앱이 켜질 때, 기록이 끝났을 때
        .onChange(of: account.uid, initial: true) { summary.follow(account.uid) }
        .onChange(of: crews.ids) { if !crews.ids.isEmpty { summary.sync() } }
        .onChange(of: phase) { if phase == .active && !crews.ids.isEmpty { summary.sync() } }
        // 계정 삭제(R13): 끝내지 못한 삭제는 앱을 켜거나 다시 볼 때 잇는다. 확인·완료·실패 시트는 어느 화면에서든 뜬다.
        .environment(deletion)
        .task(id: phase) { if phase == .active { await deletion.resume() } }
        .task {
            switch DebugFailures.deleteSheet {
            case "confirm": deletion.phase = .confirm
            case "done": deletion.phase = .done
            case "failed": deletion.phase = .failed
            default: break
            }
        }
        .sheet(isPresented: Binding(get: { deletion.phase != .idle }, set: { if !$0 { deletion.close() } })) {
            AccountDeleteSheet(deletion: deletion)
        }
        .onChange(of: recorder.recording == nil) { _, ended in if ended && !crews.ids.isEmpty { summary.sync() } }
        .alert("이 기기에는 기록이 없어요. 크루 합계를 이 기기 기준으로 바꿀까요?",
               isPresented: Binding(get: { summary.askReplace != nil }, set: { if !$0 { summary.askReplace = nil } }),
               presenting: summary.askReplace) { s in
            Button("그대로 두기", role: .cancel) { summary.answer(replace: false, season: s.season) }
            Button("이 기기 기준으로 바꾸기", role: .destructive) { summary.answer(replace: true, season: s.season) }
        } message: { s in
            Text("크루 순위에는 이번 시즌 \(s.visitDays)일 · \(s.runs)회가 있어요. 바꾸면 이 기기 기록(0회)으로 보여요.")
        }
        // Live Activity를 누르면 기록 중 화면(S5) (R23)
        .onOpenURL { url in
            // 초대 링크(Universal Links 단계에서 앱으로 열림) → 크루 탭에서 S16
            if url.host == Crews.inviteURL("x").host, let t = Crews.token(from: url.absoluteString) {
                tab = .crew
                crews.pendingInvite = t
                return
            }
            guard url == RecordingActivityAttributes.url, recorder.recording != nil else { return }
            tab = .record
            showRecording = true
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            page(HomeView(recorder: recorder, showRecording: $showRecording, setupShown: setup))
                .tabItem { Label("기록", systemImage: "figure.skiing.downhill") }.tag(Tab.record)
            page(SeasonView(db: recorder.db))
                .tabItem { Label("시즌", systemImage: "calendar") }.tag(Tab.season)
            page(CrewTab(account: account, crews: crews, summary: summary))
                .tabItem { Label("크루", systemImage: "person.3") }.tag(Tab.crew)
        }
    }

    /// iOS 17.6~25: 탭 막대 위에 같은 내용의 반투명 막대
    @ViewBuilder private func page(_ content: some View) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if recorder.recording != nil {
                    RecordingBar(recorder: recorder) { tab = .record; showRecording = true }
                        .background(.regularMaterial)
                        .overlay(alignment: .top) { Divider() }
                }
            }
        }
    }
}

private extension View {
    /// 기록 중일 때만 탭 막대 위 유리 캡슐. 26.1부터는 isEnabled로 켜고 끈다.
    @available(iOS 26, *)
    @ViewBuilder func recordingAccessory(_ on: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: on, content: content)
        } else if on {
            tabViewBottomAccessory(content: content)
        } else {
            self
        }
    }
}

/// "● 기록 중 · 하이원 · 12회 · 2:14:08 ›". 멈추면 빨간 사각형과 굵은 "기록 멈춤". 누르면 기록 중 화면.
struct RecordingBar: View {
    var recorder: Recorder
    var open: () -> Void

    var body: some View {
        if let rec = recorder.recording {
            let stopped = recorder.status != .recording
            let runs = recorder.today.runs.count
            Button(action: open) {
                HStack(spacing: 8) {
                    if stopped {
                        RoundedRectangle(cornerRadius: 2).fill(Color.stopRed).frame(width: 9, height: 9)
                    } else {
                        Circle().fill(Color.accentFill).frame(width: 9, height: 9)
                    }
                    Text(stopped ? "기록 멈춤" : "기록 중").fontWeight(stopped ? .heavy : .semibold)
                    Text("\(Resort.name(rec.resortId)) · \(runs)회").foregroundStyle(Color.secondaryText).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(rec.startedAt, style: .timer).monospacedDigit().fontWeight(.semibold)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
                }
                .font(.subheadline)
                .foregroundStyle(Color.primaryText)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                // 탭 막대처럼 한 줄에 머문다. 아주 큰 글씨에서는 길게 누르면 확대해 보여 준다.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            .buttonStyle(.plain)
            .accessibilityShowsLargeContentViewer()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(stopped ? "기록 멈춤" : "기록 중"), \(Resort.name(rec.resortId)), \(runs)회")
            .accessibilityValue(Text(rec.startedAt, style: .timer))
            .accessibilityHint("기록 중 화면 열기")
            .accessibilityAddTraits(.isButton)
        }
    }
}
