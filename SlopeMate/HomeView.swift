import SwiftUI
import UIKit

/// S2 기록 홈 (확정 시안 v10, S2 상태 v1·저장 공간 v3).
struct HomeView: View {
    @Bindable var recorder: Recorder
    @State private var homes: [String] = []
    @State private var days: [Stats.Day] = []
    @State private var pass: PassSummary?
    @State private var loaded = false
    @State private var lowStorage = false
    @State private var weatherCache = WeatherCache()
    @State private var weather: WeatherLoad = .loading
    @State private var weatherRetry = 0
    @State private var page: Int? = 0
    @Binding var showRecording: Bool
    /// S1이 떠 있는지. 닫히면 홈 리조트·날씨·시작 기본값을 다시 읽는다.
    var setupShown = false
    /// 앱을 켰을 때 이어지는 기록이면 한 번만 S5를 연다. 탭을 오갈 때는 다시 열지 않는다.
    @State private var launched = false
    @State private var settingsEdits = 0
    /// S3·동의 시트
    @State private var step: StartStep?
    /// S3에서 고른 리조트. 시트가 닫힌 뒤 동의(첫 기록) → 권한(S4) → 시작으로 넘긴다.
    @State private var chosen: String?
    /// S7 끝내기·영업일 끝 안내 뒤 여는 하루 기록(S6)
    @State private var openDay: Stats.Day?
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .largeTitle) private var bigSize = 64
    @ScaledMetric(relativeTo: .title) private var unitSize = 28

    /// 기록 시작 기본 리조트 (R1). 홈 리조트가 없으면 nil → 시작할 때 고른다.
    private var startResort: String? {
        homes.isEmpty ? nil : AppDatabase.defaultResort(homes: homes, last: Recorder.lastResortId)
    }

    /// 날씨 기준 리조트 (04-flows S2): 기록 시작 기본값과 같은 규칙, 홈 리조트가 없으면 숨김.
    private var weatherResort: Resort? {
        startResort.flatMap { id in Resort.all.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    cards
                    #if TESTFLIGHT
                    VStack(alignment: .leading) { ExportSection(recorder: recorder) }
                        .padding(.horizontal, 20).padding(.top, 24)
                    #endif
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(FadeBackground())
            .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: Binding(get: { openDay != nil }, set: { if !$0 { openDay = nil } })) {
                if let openDay { DayDetailView(db: recorder.db, day: openDay) }
            }
        }
        .task(id: reloadKey) { await reload() }
        .task(id: "\(weatherResort?.id ?? "")-\(weatherRetry)") { await loadWeather() }
        .onAppear {
            guard !launched else { return }
            launched = true
            if recorder.recording != nil { showRecording = true }
        }
        .onChange(of: recorder.recording?.id) { old, new in
            if old == nil, new != nil { showRecording = true }
        }
        // S4는 S5와 같은 전체 화면에 띄워, 권한이 생겨 시작하면 그 자리에서 S5로 바뀐다
        .onChange(of: recorder.pendingStart) { _, new in
            if new != nil { showRecording = true } else if recorder.recording == nil { showRecording = false }
        }
        .fullScreenCover(isPresented: $showRecording, onDismiss: recorder.cancelPendingStart) {
            if recorder.pendingStart != nil && recorder.recording == nil {
                PermissionView(recorder: recorder) { showRecording = false }
            } else {
                RecordingView(recorder: recorder) { showRecording = false }
            }
        }
        .sheet(item: $step, onDismiss: next) { s in
            switch s {
            case .pick: ResortPickSheet(homes: homes) { chosen = $0; step = nil }
            case .consent:
                ConsentSheet { yes in
                    try? Settings.answerConsent(yes, db: recorder.db) // 동의 저장 실패해도 기록은 시작한다
                    step = nil
                }
            }
        }
        .sheet(item: resumePrompt) { p in
            ResumeSheet(db: recorder.db, prompt: p) {
                recorder.answerResume(true)
            } end: {
                guard case .resume(let rec) = p else { return }
                recorder.answerResume(false)
                // 묻는 동안 06:00이 지났으면 영업일 끝 안내가 대신 뜬다
                if recorder.dayEndNotice?.id != rec.id { openDay = recorder.db.day(of: rec) }
            } openDay: {
                guard case .dayEnd(let rec) = p else { return }
                recorder.acknowledgeDayEnd()
                openDay = recorder.db.day(of: rec)
            }
        }
    }

    private enum StartStep: String, Identifiable { case pick, consent; var id: String { rawValue } }

    /// 시트가 닫힌 뒤: 첫 기록이면 동의, 아니면 시작(권한이 없으면 S4)
    private func next() {
        guard let id = chosen else { return }
        if Settings.consentAsked {
            chosen = nil
            recorder.requestStart(resortId: id)
        } else {
            step = .consent
        }
    }

    /// S7 묻기가 먼저, 없으면 영업일 끝 안내. 영업일 끝 안내를 끌어 내리면 확인한 것으로 본다.
    private var resumePrompt: Binding<ResumePrompt?> {
        Binding(get: { recorder.pendingResume.map(ResumePrompt.resume) ?? recorder.dayEndNotice.map(ResumePrompt.dayEnd) },
                set: { if $0 == nil, recorder.pendingResume == nil { recorder.acknowledgeDayEnd() } })
    }

    private var reloadKey: String {
        "\(recorder.recording?.id.uuidString ?? "-")-\(recorder.todayRecordings.count)-\(recorder.today.runs.count)-\(setupShown)-\(settingsEdits)"
    }

    // MARK: 위: 홈 리조트, 설정, 이번 시즌

    private var header: some View {
        let totals = Stats.totals(days)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(homes.isEmpty ? "홈 리조트 없음" : homes.map { Resort.name($0) }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Color.secondaryText)
                Spacer()
                NavigationLink {
                    SettingsView(db: recorder.db) { settingsEdits += 1 }
                } label: {
                    Image(systemName: "gearshape").font(.title3).frame(width: 44, height: 44).glassCircle()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("설정")
            }
            .padding(.bottom, 14)

            Text("이번 시즌").font(.headline).foregroundStyle(Color.primaryText)
            if loaded && days.isEmpty {
                Text("스키장에 도착하면\n기록 시작을 누르세요").font(.title.bold()).foregroundStyle(Color.primaryText)
                Text("아직 기록이 없어요").font(.subheadline).foregroundStyle(Color.secondaryText)
            } else {
                (Text("\(totals.visitDays)").font(.system(size: bigSize, weight: .bold))
                    + Text("일").font(.system(size: unitSize, weight: .bold)))
                    .monospacedDigit().foregroundStyle(Color.accentText)
                    .accessibilityLabel("방문일 \(totals.visitDays)일")
                Text("\(totals.runs)회 · \(RecordFormat.km(totals.distance))")
                    .font(.subheadline).foregroundStyle(Color.secondaryText)
            }
        }
        .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24)
        .redacted(reason: loaded ? [] : .placeholder)
    }

    // MARK: 옆으로 넘기는 카드: 날씨 → 최근 기록 → 시즌권

    private enum Card: Int { case weather, recent, howTo, pass }

    private var cardList: [Card] {
        var c: [Card] = []
        if weatherResort != nil { c.append(.weather) }
        c.append(loaded && days.isEmpty ? .howTo : .recent)
        if pass != nil { c.append(.pass) }
        return c
    }

    private var cards: some View {
        let list = cardList
        return VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(list.enumerated()), id: \.element) { i, card in
                        cardView(card).id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $page)

            if list.count > 1 {
                HStack(spacing: 8) {
                    ForEach(list.indices, id: \.self) { i in
                        Circle().fill(i == (page ?? 0) ? Color.accentText : Color.cardBorder).frame(width: 7, height: 7)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private func cardView(_ card: Card) -> some View {
        switch card {
        case .weather: weatherCard
        case .recent:
            if let day = days.first(where: \.isVisit) ?? days.first {
                NavigationLink { DayDetailView(db: recorder.db, day: day) } label: {
                    let t = Stats.totals([day])
                    HomeCard(icon: "clock", label: "최근 기록 · \(HomeData.monthDay(day.date))") {
                        Text("\(t.runs)회").font(.title.bold())
                        Text("\(RecordFormat.km(t.distance)) · 고도차 \(Int(t.drop).formatted())m").font(.subheadline)
                    }
                }
                .buttonStyle(.plain)
            } else {
                HomeCard(icon: "clock", label: "최근 기록") { EmptyView() }.redacted(reason: .placeholder)
            }
        case .howTo:
            HomeCard(icon: "list.number", label: "기록 방법") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(["리프트 전에 기록 시작", "휴대폰은 주머니에", "다 타면 종료 길게 누르기"].enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1)").fontWeight(.bold).monospacedDigit().foregroundStyle(Color.accentText)
                            Text(s)
                        }
                        .font(.subheadline)
                    }
                }
            }
        case .pass:
            if let pass {
                HomeCard(icon: "ticket", label: pass.label) {
                    if let v = pass.value {
                        Text("\(Int(v.perVisit.rounded()).formatted())원").font(.title.bold())
                        Text("리프트권이었다면 \(pass.ticket.formatted())원").font(.subheadline)
                    } else {
                        Text("방문 전").font(.title.bold())
                        Text("방문하면 1회 방문당 금액을 계산해요").font(.subheadline)
                    }
                }
            }
        }
    }

    @ViewBuilder private var weatherCard: some View {
        let name = weatherResort.map { "\($0.name) 날씨" } ?? "날씨"
        switch weather {
        case .loading:
            HomeCard(icon: "cloud.sun", label: name, dim: true) {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.surface).frame(width: 120, height: 26)
                    RoundedRectangle(cornerRadius: 8).fill(Color.surface).frame(width: 160, height: 14)
                }
                .padding(.top, 6).opacity(0.6)
            } footer: { attributionLine }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name) 불러오는 중")
        case .failed:
            HomeCard(icon: "cloud.sun", label: name) {
                Text("날씨를 불러오지 못했어요").font(.headline)
            } footer: {
                Button { DebugFailures.weatherFails = false; weatherRetry += 1 } label: {
                    Label("다시 시도", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                        .padding(.horizontal, 18).frame(minHeight: 44)
                        .background(Color.surface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        case .loaded(let s):
            NavigationLink {
                WeatherDetailView(cache: weatherCache, homes: homes, selected: weatherResort?.id ?? homes[0])
            } label: {
                HomeCard(icon: s.current.symbolName, label: name) {
                    Text("\(WeatherFormat.temp(s.current.temperature)) \(s.current.condition)").font(.title.bold())
                    if let est = SnowForecast.estimate(hours: s.hours, now: .now) {
                        HStack(spacing: 4) {
                            Text("예상 설질 \(est.level.label)")
                            ForecastTag()
                        }
                        .font(.subheadline)
                    }
                } footer: { attributionLine }
            }
            .buttonStyle(.plain)
        }
    }

    private var attributionLine: some View {
        Text("Apple Weather · 데이터 출처").font(.caption).foregroundStyle(Color.secondaryText)
    }

    // MARK: 아래: 경고와 기록 시작 (기록 중에는 숨김)

    @ViewBuilder private var bottom: some View {
        if recorder.recording == nil {
            VStack(spacing: 12) {
                // 읽기 순서도 경고가 먼저 (decisions 2026-11-09)
                if let b = recorder.blocked {
                    StatusBanner(kind: .stop, icon: "location.slash", title: HomeData.blockedTitle(b),
                                 message: "설정에서 위치 권한을 켜면 기록할 수 있어요. 위치 기록은 이 iPhone에만 저장돼요.",
                                 action: ("설정 열기", { openURL(URL(string: UIApplication.openSettingsURLString)!) }))
                } else if case .failed(let msg) = recorder.status, !showRecording {
                    let (title, body) = HomeData.split(msg)
                    StatusBanner(kind: .stop, icon: "stop.circle", title: title, message: body)
                }
                if lowStorage {
                    StatusBanner(kind: .warning, icon: "externaldrive.badge.exclamationmark", title: "저장 공간이 부족해요",
                                 message: "기록이 중간에 멈출 수 있어요", compact: true)
                }
                startCard
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
        }
    }

    private var startCard: some View {
        let subtitle: String = {
            guard let id = startResort else { return "시작할 때 리조트를 골라요" }
            return "\(Resort.name(id)) · \(id == Recorder.lastResortId ? "마지막으로 기록한 리조트" : "첫 번째 홈 리조트")"
        }()
        return Button {
            step = .pick
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("기록 시작").font(.title2.bold())
                    Text(subtitle).font(.subheadline)
                }
                Spacer(minLength: 0)
                Image(systemName: "record.circle")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.frost)
                    .frame(width: 56, height: 56)
                    .background(Color.onAccent, in: Circle())
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.onAccent)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        }
        .buttonStyle(StartCardStyle())
    }

    // MARK: 불러오기

    private func reload() async {
        homes = (try? recorder.db.homeResorts()) ?? []
        lowStorage = Recorder.lowStorage
        let db = recorder.db, s = HomeData.currentSeason()
        days = await Task.detached(priority: .userInitiated) {
            Stats.days((try? HomeData.days(db, since: HomeData.seasonStart(s))) ?? [], inSeason: s)
        }.value
        pass = PassSummary(db: db, season: s, days: days)
        loaded = true
    }

    private func loadWeather() async {
        guard let resort = weatherResort else { return }
        weather = .loading
        do {
            let snapshot = try await weatherCache.weather(for: resort)
            if !Task.isCancelled { weather = .loaded(snapshot) }
        } catch {
            if !Task.isCancelled { weather = .failed }
        }
    }
}

/// 홈 카드 하나 (250×200, 아이콘 바로 아래 본문, 출처·버튼 줄은 맨 아래)
private struct HomeCard<Content: View, Footer: View>: View {
    var icon: String
    var label: String
    var dim = false
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            IconCircle(systemName: icon).opacity(dim ? 0.5 : 1).padding(.bottom, 10)
            Text(label).font(.subheadline).foregroundStyle(Color.secondaryText)
            content.foregroundStyle(Color.primaryText)
            Spacer(minLength: 8)
            footer
        }
        .padding(18)
        .frame(width: 250, alignment: .leading)
        .frame(minHeight: 200, alignment: .top)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.cardBorder))
        .contentShape(RoundedRectangle(cornerRadius: 24))
    }
}

private extension HomeCard where Footer == EmptyView {
    init(icon: String, label: String, dim: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(icon: icon, label: label, dim: dim, content: content, footer: { EmptyView() })
    }
}

private struct StartCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.accentFill.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 24))
    }
}

/// 시즌권 카드 값 (R8): 1장이면 그 시즌권, 여러 장이면 합계.
struct PassSummary {
    var label: String
    var value: PassValue.Value?
    var ticket: Int

    init?(db: AppDatabase, season: String, days: [Stats.Day]) {
        guard let passes = try? db.passes(season: season), let first = passes.first else { return nil }
        let r = PassValue.compute(passes, days: days, season: season)
        if passes.count == 1 {
            label = "\(first.pass.name) · 1회 방문당"
            value = r.perPass[first.pass.id] ?? nil
        } else {
            label = "시즌권 \(passes.count)장 · 1회 방문당"
            value = r.total
        }
        ticket = r.ticketValue.values.reduce(0, +)
    }
}

nonisolated extension HomeData {
    /// "2026-27" → 2026-11-01 06:00 (한국)
    static func seasonStart(_ season: String) -> Date {
        let y = Int(season.prefix(4)) ?? 2026
        return seoul.date(from: DateComponents(year: y, month: 11, day: 1, hour: 6))!
    }

    static func monthDay(_ d: Date) -> String {
        let c = seoul.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)월 \(c.day ?? 0)일"
    }

    /// 오류 문구의 첫 문장을 제목으로
    static func split(_ msg: String) -> (String, String?) {
        guard let r = msg.range(of: ". ") else { return (msg, nil) }
        return (String(msg[..<r.lowerBound]), String(msg[r.upperBound...]))
    }

    static func blockedTitle(_ b: Recorder.Blocked) -> String {
        switch b {
        case .servicesOff: "위치 서비스가 꺼져 있어요"
        case .denied: "위치 권한이 없어 기록할 수 없어요"
        case .reducedAccuracy: "정확한 위치가 꺼져 있어요"
        }
    }
}

extension Resort {
    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
}

extension Color {
    /// 기록 시작 카드의 원 안 아이콘 (시안: 밝게·어둡게 모두 프로스트)
    static let frost = Color(light: 0x5CE1E6, dark: 0x5CE1E6)
}

extension View {
    /// 유리 원 버튼 (iOS 26). 17.6~25는 유리 대신 강조색 아이콘 (B1 v1).
    @ViewBuilder func glassCircle() -> some View {
        if #available(iOS 26, *) {
            self.foregroundStyle(Color.primaryText).glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.foregroundStyle(Color.accentText)
        }
    }
}
