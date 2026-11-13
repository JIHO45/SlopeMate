import SwiftUI
import UserNotifications
import UIKit

/// S5 기록 중 (확정 시안 v7, S5 상태 v1·자동 재개 v2·저장 실패 v3). 기록 탭에서 홈 위에 전체 화면으로 뜬다.
struct RecordingView: View {
    @Bindable var recorder: Recorder
    var close: () -> Void

    /// 보고 있는 기록. 저장 실패로 Recorder의 기록이 사라져도 리조트와 시작 시각을 보여준다.
    @State private var rec: Recording?
    /// 기록이 끝난(또는 멈춘) 시각
    @State private var endedAt: Date?
    /// 사용자가 종료해 하루 합계를 잠깐 보여주는 중
    @State private var finished = false
    @State private var progress = 0.0
    @State private var confirmStop = false
    @State private var rated: [Date: SnowRating.Value] = [:]
    @State private var battery = UIDevice.current.batteryLevel
    @State private var day: Stats.Day?
    @State private var showDay = false
    /// 알림 권한(R49 카드). 읽기 전에는 nil이라 카드를 띄우지 않는다
    @State private var notify: UNAuthorizationStatus?
    @State private var notifyDismissed = Settings.notifyCardDismissed
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .largeTitle) private var midSize = 44
    @ScaledMetric(relativeTo: .largeTitle) private var bigSize = 120
    @ScaledMetric(relativeTo: .title3) private var unitSize = 20

    private static let holdTime = 1.5

    var body: some View {
        NavigationStack {
            // 설질 칸·배너는 숫자 아래 흐름에 둔다(아래 고정 영역에 두면 작은 화면에서 숫자를 가린다).
            // 화면이 남으면 아래로 붙인다.
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        numbers
                        Spacer(minLength: 24)
                        cards
                    }
                    .frame(minHeight: geo.size.height)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(FadeBackground(recording: true))
            .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showDay) {
                if let day { DayDetailView(db: recorder.db, day: day) }
            }
        }
        .onAppear {
            rec = recorder.recording
            if let rec, let saved = try? recorder.db.snowRatings(rec) {
                rated = Dictionary(saved.map { ($0.runStart, $0.value) }, uniquingKeysWith: { $1 })
            }
            UIDevice.current.isBatteryMonitoringEnabled = true
            battery = UIDevice.current.batteryLevel
        }
        .task { notify = await ForgottenStop.status() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            battery = UIDevice.current.batteryLevel
        }
        .onChange(of: recorder.recording?.id) { _, id in
            if id != nil {
                rec = recorder.recording
                endedAt = nil
            } else {
                endedAt = endedAt ?? .now
                // 영업일 끝 자동 종료 등: 보여줄 것이 없으면 홈으로
                if !finished, !failedWithoutRecording { close() }
            }
        }
        .sensoryFeedback(.success, trigger: finished)
    }

    private var failedWithoutRecording: Bool {
        if case .failed = recorder.status, recorder.recording == nil { return true }
        return false
    }

    private var stopped: Bool {
        if recorder.recording == nil { return !finished }
        return recorder.status != .recording
    }

    // MARK: 위: 닫기, 리조트, 마지막 위치

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44).glassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("기록 중 화면 닫기")

            VStack(spacing: 0) {
                Text(rec.map { Resort.name($0.resortId) } ?? "").font(.headline)
                TimelineView(.periodic(from: .now, by: 5)) { ctx in
                    Text(lastLocation(now: ctx.date)).font(.caption).foregroundStyle(Color.secondaryText)
                }
            }
            .frame(maxWidth: .infinity)

            Group {
                if stopped {
                    RoundedRectangle(cornerRadius: 2).fill(Color.stopRed).frame(width: 10, height: 10)
                        .accessibilityLabel("기록 멈춤")
                } else {
                    Circle().fill(Color.accentText).frame(width: 10, height: 10)
                        .accessibilityLabel(finished ? "기록 끝" : "기록 중")
                }
            }
            .frame(width: 44, alignment: .trailing)
        }
        .foregroundStyle(Color.primaryText)
        .padding(.horizontal, 16)
    }

    private func lastLocation(now: Date) -> String {
        guard let t = recorder.points.last?.t else { return recorder.recording == nil ? "" : "위치를 찾는 중" }
        let s = max(0, Int(now.timeIntervalSince(t)))
        return s < 60 ? "마지막 위치 \(s)초 전" : s < 3600 ? "마지막 위치 \(s / 60)분 전" : "마지막 위치 \(t.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: 숫자: 경과 시간, 하강(가장 큼), 거리

    private var numbers: some View {
        let today = recorder.today
        return VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(finished ? "기록 시간" : "경과 시간").font(.subheadline).foregroundStyle(Color.secondaryText)
                elapsed.font(.system(size: midSize, weight: .bold)).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .padding(.top, 36)

            VStack(spacing: 2) {
                stateLine
                Text("\(today.runs.count)").font(.system(size: bigSize, weight: .bold)).monospacedDigit()
                    .foregroundStyle(today.runs.isEmpty ? Color.secondaryText : Color.primaryText)
                    .minimumScaleFactor(0.5).lineLimit(1)
                Text("하강").font(.headline)
            }
            .accessibilityElement(children: .combine)
            .padding(.top, 52)

            VStack(spacing: 2) {
                Text("거리").font(.subheadline).foregroundStyle(Color.secondaryText)
                (Text(String(format: "%.1f", today.distance / 1000)).font(.system(size: midSize, weight: .bold))
                    + Text("km").font(.system(size: unitSize, weight: .bold)))
                    .monospacedDigit()
                if usingGPSAltitude {
                    Label("GPS 고도로 기록 중 · 고도 정확도 낮음", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(Color.secondaryText).padding(.top, 10)
                }
            }
            .accessibilityElement(children: .combine)
            .padding(.top, 52).padding(.bottom, 24)
        }
        .foregroundStyle(Color.primaryText)
    }

    @ViewBuilder private var elapsed: some View {
        if let rec {
            // 시안대로 1시간 전에도 "0:12:40"
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Duration.seconds(max(0, (endedAt ?? ctx.date).timeIntervalSince(rec.startedAt)))
                    .formatted(.time(pattern: .hourMinuteSecond)))
            }
        } else {
            Text("0:00:00")
        }
    }

    /// 기압이 없는 위치점으로 판정 중 (동작 권한 없음·기압계 없음)
    private var usingGPSAltitude: Bool {
        recorder.recording != nil && recorder.points.last.map { $0.baroAlt == nil } == true
    }

    @ViewBuilder private var stateLine: some View {
        let today = recorder.today
        Group {
            if finished {
                Label("기록을 마쳤어요", systemImage: "checkmark.circle").foregroundStyle(Color.accentText)
            } else if stopped {
                Label("기록 멈춤", systemImage: "pause.circle").foregroundStyle(Color.secondaryText)
            } else if today.runs.isEmpty {
                Label("첫 하강을 기다리는 중", systemImage: "cablecar").foregroundStyle(Color.secondaryText)
            } else if let run = today.runs.last, let t = recorder.points.last?.t, run.end >= t.addingTimeInterval(-20) {
                Label("내려가는 중", systemImage: "arrow.down.right").foregroundStyle(Color.accentText)
            } else {
                // ponytail: 리프트·대기 구분은 실시간 판정이 없어 "기록 중"으로 둠
                Label("기록 중", systemImage: "record.circle").foregroundStyle(Color.accentText)
            }
        }
        .font(.subheadline.weight(.semibold))
    }

    // MARK: 아래: 설질 칸, 상태 배너, 종료

    @ViewBuilder private var cards: some View {
        if !finished {
            VStack(spacing: 16) {
                if let run = recorder.snowTarget, let rec { snowCard(run, rec: rec) }
                banner
                if showNotifyCard { notifyCard }
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
    }

    private var bottom: some View {
        VStack(spacing: 16) {
            if finished {
                EmptyView()
            } else if recorder.recording == nil {
                HStack(spacing: 12) {
                    Button("닫기", action: close).buttonStyle(CapsuleButtonStyle(fill: .surface, text: .primaryText, expand: false))
                    Button("하루 기록 보기", action: openDay).buttonStyle(CapsuleButtonStyle(fill: .accentFill, text: .onAccent))
                }
            } else {
                endButton
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    @ViewBuilder private var banner: some View {
        if let b = currentBanner { b }
    }

    /// 지금 띄울 상태 배너 하나(07 6장 "배너는 하나씩")
    private var currentBanner: StatusBanner? {
        if case .failed(let msg) = recorder.status {
            let (title, body) = HomeData.split(msg)
            return StatusBanner(kind: .stop, icon: "stop.circle", title: title, message: body)
        } else if case .paused(let b) = recorder.status {
            return StatusBanner(kind: .stop, icon: "stop.circle", title: Self.pausedTitle(b), message: "멈춘 동안은 기록 없음으로 남아요",
                                action: ("설정 열기", { openURL(URL(string: UIApplication.openSettingsURLString)!) }))
        } else if let gap = recorder.autoResumedGap {
            return StatusBanner(kind: .info, icon: "arrow.clockwise", title: "자동으로 이어서 기록 중", message: autoResumedText(gap))
        } else if let level = DebugFailures.batteryLevel ?? (UIDevice.current.batteryState == .charging ? nil : battery),
                  level >= 0, level <= 0.15 {
            return StatusBanner(kind: .warning, icon: "battery.25", title: "배터리가 부족해요",
                                message: "\(Int((level * 100).rounded()))% 남음 · 지금까지 기록은 저장돼 있어요")
        } else if recorder.status == .recording, let p = recorder.points.last,
                  (DebugFailures.weakSignal ? RunDetector.Params().maxHAcc + 1 : p.hAcc) > RunDetector.Params().maxHAcc {
            return StatusBanner(kind: .warning, icon: "exclamationmark.triangle", title: "위치 신호가 약해요",
                                message: "기록은 계속돼요. 하늘이 트인 곳에서 나아질 수 있어요")
        }
        return nil
    }

    // MARK: 종료 잊음 알림 카드 (R49, 확정 시안 v2)

    /// 알림 권한을 아직 묻지 않았고 닫은 적 없을 때. 배너나 설질 칸이 있으면 숨겼다가 없어지면 다시 보인다.
    private var showNotifyCard: Bool {
        notify == .notDetermined && !notifyDismissed && recorder.status == .recording
            && currentBanner == nil && recorder.snowTarget == nil
    }

    private var notifyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("기록을 켜 두고 떠나면 알려 드릴까요?").font(.headline)
                Text("1시간 하강이 없거나 5km 넘게 벗어나면 알려요.").font(.subheadline).foregroundStyle(Color.secondaryText)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                Button("괜찮아요") {
                    Settings.notifyCardDismissed = true
                    notifyDismissed = true
                }
                .font(.headline).foregroundStyle(Color.primaryText)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Capsule())
                Button {
                    Task {
                        await ForgottenStop.request()
                        notify = await ForgottenStop.status()
                    }
                } label: {
                    Text("알림 받기").font(.headline.weight(.bold)).foregroundStyle(Color.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.surface, in: Capsule())
                }
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.primaryText)
        .card(padding: 16)
    }

    private func autoResumedText(_ gap: TimeInterval) -> String {
        let min = max(1, Int((gap / 60).rounded()))
        guard let from = recorder.autoResumedFrom else { return "끊긴 \(min)분은 기록 없음" }
        let hm = { (d: Date) in String(format: "%02d:%02d", HomeData.seoul.component(.hour, from: d), HomeData.seoul.component(.minute, from: d)) }
        return "끊긴 \(hm(from))~\(hm(from.addingTimeInterval(gap)))(\(min)분)은 기록 없음"
    }

    static func pausedTitle(_ b: Recorder.Blocked) -> String {
        switch b {
        case .servicesOff: "위치 서비스가 꺼져 기록이 멈췄어요"
        case .denied: "위치 권한이 꺼져 기록이 멈췄어요"
        case .reducedAccuracy: "정확한 위치가 꺼져 기록이 멈췄어요"
        }
    }

    private func snowCard(_ run: RunDetector.Run, rec: Recording) -> some View {
        let slope = SlopeNames.isShown(rec.resortId)
            ? SlopeMap.cached(resortId: rec.resortId)?.slopes.first { $0.id == run.slopeId }?.name : nil
        let title = slope.map { "방금: \($0) · 설질" } ?? "방금 하강의 설질"
        let labels: [(SnowRating.Value, String)] = [(.ice, "아이스"), (.ok, "적당함"), (.slush, "슬러시")]
        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(labels, id: \.0) { value, label in
                    let on = rated[run.start] == value
                    Button {
                        recorder.rateSnow(value)
                        rated[run.start] = value
                    } label: {
                        Text(label).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(on ? Color.onAccent : Color.primaryText)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(on ? Color.accentFill : Color.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }
        .foregroundStyle(Color.primaryText)
        .card(padding: 16)
    }

    /// 길게 눌러 종료. VoiceOver에서는 두 번 탭 → 확인 창.
    private var endButton: some View {
        Label("길게 눌러 종료", systemImage: "stop.fill")
            .font(.headline)
            .foregroundStyle(Color.onAccent)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background {
                GeometryReader { g in
                    Color.accentFill.overlay(alignment: .leading) {
                        Color.onAccent.opacity(0.2).frame(width: g.size.width * progress)
                    }
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: Self.holdTime) {
                stop()
            } onPressingChanged: { pressing in
                withAnimation(pressing ? .linear(duration: Self.holdTime) : .easeOut(duration: 0.2)) { progress = pressing ? 1 : 0 }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("기록 종료")
            .accessibilityHint("두 번 탭하면 종료할지 물어요")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { confirmStop = true }
            .alert("기록을 끝낼까요?", isPresented: $confirmStop) {
                Button("종료", role: .destructive, action: stop)
                Button("계속 기록", role: .cancel) {}
            }
    }

    private func stop() {
        progress = 0
        recorder.stop()
        guard recorder.recording == nil else { return }  // 종료를 저장하지 못함: 배너로 알림
        finished = true
        endedAt = endedAt ?? .now
        // 하루 합계를 잠깐 보여주고 홈으로
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            close()
        }
    }

    private func openDay() {
        guard let rec else { return }
        let start = BusinessDay.start(of: rec.startedAt)
        day = (try? HomeData.days(recorder.db, since: start))?.first { $0.resortId == rec.resortId && $0.date == start }
        showDay = day != nil
    }
}

/// 상태 배너 (07-visual-design 2·4장): 경고는 중립 면에 노란 아이콘, 멈춤은 빨간 면, 자동 재개는 중립 면에 강조색 아이콘.
/// 홈(S2)과 기록 중(S5)이 함께 쓴다.
struct StatusBanner: View {
    enum Kind { case info, warning, stop }
    var kind: Kind
    var icon: String
    var title: String
    var message: String?
    var action: (label: String, run: () -> Void)?
    /// 홈의 저장 공간 경고처럼 한 줄 높이로
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: compact ? .center : .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(iconColor)
                    .frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(compact ? .subheadline.weight(.semibold) : .headline)
                    if let message {
                        Text(message).font(compact ? .footnote : .subheadline)
                            .foregroundStyle(kind == .stop ? fg : Color.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            if let action {
                Button(action: action.run) {
                    Text(action.label).font(.headline).foregroundStyle(fg)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(fg))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .foregroundStyle(fg)
        .padding(.vertical, compact ? 12 : 14).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: compact ? 64 : 0, alignment: .leading)
        .background(kind == .stop ? Self.stopBg : Self.neutralBg, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(kind == .stop ? [] : .updatesFrequently)
    }

    private var fg: Color { kind == .stop ? Self.stopFg : .primaryText }
    private var iconColor: Color {
        switch kind {
        case .info: .accentText
        case .warning: Self.warn
        case .stop: Self.stopFg
        }
    }

    // 확정 S5 상태 시안 값
    private static let neutralBg = Color(light: 0xEEF2F4, dark: 0x18252B)
    private static let stopBg = Color(light: 0xFDE8E8, dark: 0x3A1618)
    private static let stopFg = Color(light: 0x8A1C1C, dark: 0xFFB4B4)
    private static let warn = Color(light: 0xA87400, dark: 0xF2B92E)
}

private struct CapsuleButtonStyle: ButtonStyle {
    var fill: Color
    var text: Color
    var expand = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline).foregroundStyle(text)
            .padding(.horizontal, 36)
            .frame(maxWidth: expand ? .infinity : nil, minHeight: 60)
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}
