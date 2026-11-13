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
    /// 기록 시작 캡슐(S2 v15): 누르면 기록 탭으로 가서 S3. 보조 줄은 HomeView가 정한다.
    @State private var startBar = StartBarModel()
    /// S1: 첫 실행에 한 번
    @State private var setup = !Settings.homeSetupDone
    /// 익명 표본 보내기(R12): 앞에 올 때마다
    @State private var sampler: SampleSender?

    enum Tab { case record, season, crew }

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                tabs.recordingAccessory(recorder.recording != nil) { RecordingBar(recorder: recorder) { tab = .record; showRecording = true } }
            } else {
                tabs
            }
        }
        .environment(startBar)
        .onChange(of: recorder.recording == nil, initial: true) { _, idle in startBar.visible = idle }
        .onAppear { startBar.open = { tab = .record; startBar.requests += 1 } }
        .fullScreenCover(isPresented: $setup) { FirstRunView(db: recorder.db) { setup = false } }
        // 시즌 합계를 크루 순위로(R15): 크루가 생기거나 바뀔 때, 앱이 켜질 때, 기록이 끝났을 때
        .onChange(of: account.uid, initial: true) { summary.follow(account.uid) }
        .onChange(of: crews.ids) { if !crews.ids.isEmpty { summary.sync() } }
        .onChange(of: phase) { if phase == .active && !crews.ids.isEmpty { summary.sync() } }
        // 계정 삭제(R13): 끝내지 못한 삭제는 앱을 켜거나 다시 볼 때 잇는다. 확인·완료·실패 시트는 어느 화면에서든 뜬다.
        .environment(deletion)
        .environment(crews)
        // 처리된 내 신고 알림(R16), 오프라인이라 확인하지 못한 가입을 다시 확인
        .task(id: phase) {
            guard phase == .active else { return }
            account.recheck()
            await crews.checkReports()
        }
        .onChange(of: account.uid) { Task { await crews.checkReports() } }
        .alert(crews.reportNotice ?? "", isPresented: Binding(get: { crews.reportNotice != nil }, set: { if !$0 { crews.reportNotice = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text("신고해 주셔서 고마워요.") }
        .task(id: phase) { if phase == .active { await deletion.resume() } }
        .task(id: phase) {
            guard phase == .active else { return }
            if sampler == nil { sampler = SampleSender(db: recorder.db) }
            await sampler?.run()
            // 앞에 올 때 시작한 차량 재조회·캐시 갱신이 끝난 기록도 같은 방문에 보낸다
            // ponytail: 고정 1분 대기, 갱신 완료 알림이 생기면 그때 부르기
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await sampler?.run()
        }
        // 슬로프 이름 켜기·시간표 갱신·차단 스위치(R7, R9): 켤 때와 다시 볼 때(1시간 안에 받았으면 건너뜀),
        // 켜 둔 동안에는 1시간마다. 백그라운드로 가면 멈춘다.
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await ServerConfig.refresh()
                // refresh가 다음 시각을 미래로 정하므로 0이 될 일은 없지만, 연달아 돌지 않게 1초는 쉰다
                try? await Task.sleep(for: .seconds(max(ServerConfig.secondsUntilRefresh(), 1)))
            }
        }
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
                crews.receiveInvite(t)
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
            page(CrewTab(account: account, crews: crews, summary: summary, covered: setup))
                .tabItem { Label("크루", systemImage: "person.3") }.tag(Tab.crew)
        }
    }

    /// iOS 17.6~25: 탭 막대 위에 같은 내용의 반투명 막대 (iOS 26은 탭 막대 액세서리)
    @ViewBuilder private func page(_ content: some View) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if recorder.recording != nil { legacyRecordingBar }
        }
    }

    @ViewBuilder private var legacyRecordingBar: some View {
        if #available(iOS 26, *) {
            EmptyView()
        } else {
            RecordingBar(recorder: recorder) { tab = .record; showRecording = true }
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
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

/// 기록 시작 캡슐의 상태. 기록 중이 아닐 때 기록·시즌 탭 첫 화면 아래에 붙는다(startBarInset).
/// 들어간 화면(설정·하루 기록 등)에는 붙지 않는다. 기록 중에는 같은 자리가 기록 중 막대.
@Observable final class StartBarModel {
    var visible = true
    var subtitle = ""
    /// 누른 횟수. HomeView가 바뀌면 S3를 연다.
    var requests = 0
    @ObservationIgnored var open: () -> Void = {}
}

extension View {
    /// 탭 첫 화면 아래 기록 시작 캡슐
    func startBarInset() -> some View { modifier(StartBarInset()) }
}

private struct StartBarInset: ViewModifier {
    @Environment(StartBarModel.self) private var model: StartBarModel?
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if let model, model.visible {
                StartBar(subtitle: model.subtitle, start: model.open)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }
}

/// 기록 시작 캡슐 (S2 v15): 화면 폭, 최소 높이 64, 강조 면. "기록 시작" + 리조트 보조 줄. 누르면 S3.
struct StartBar: View {
    var subtitle: String
    var start: () -> Void

    var body: some View {
        Button(action: start) {
            HStack(spacing: 12) {
                Image(systemName: "record.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.frost)
                    .frame(width: 44, height: 44)
                    .background(Color.onAccent, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("기록 시작").font(.title3.bold())
                    Text(subtitle).font(.footnote).opacity(0.85)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.body.weight(.semibold)).accessibilityHidden(true)
            }
            .foregroundStyle(Color.onAccent)
            .padding(.leading, 10).padding(.trailing, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Color.accentFill, in: Capsule())
            .shadow(color: Color.accentText.opacity(0.25), radius: 10, y: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("리조트 고르기 열기")
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
