import SafariServices
import SwiftUI
import UIKit

/// S2 기록 홈 (확정 시안 v15, S2 상태 v1). 기록 시작 캡슐(RootView의 StartBar)을 누르면 여기서 S3를 연다.
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
    /// 지금 보이는 날씨의 리조트. 같은 리조트를 다시 읽을 때만 이전 값을 두고, 바뀌면 '불러오는 중'으로
    @State private var weatherFor: String?
    @State private var page: Int? = 0
    @Binding var showRecording: Bool
    /// S1이 떠 있는지. 닫히면 홈 리조트·날씨·시작 기본값을 다시 읽는다.
    var setupShown = false
    /// 탭 막대 위 기록 시작 캡슐: 누른 횟수가 바뀌면 S3, 보조 줄("용평 · 마지막으로 기록한 리조트")은 여기서 정한다
    @Environment(StartBarModel.self) private var startBar: StartBarModel?
    /// 앱을 켰을 때 이어지는 기록이면 한 번만 S5를 연다. 탭을 오갈 때는 다시 열지 않는다.
    @State private var launched = false
    @State private var settingsEdits = 0
    /// S3 시트
    @State private var step: StartStep?
    /// S3에서 고른 리조트. 시트가 닫힌 뒤 권한(S4) → 동의(첫 기록) → 시작으로 넘긴다(Recorder.requestStart).
    @State private var chosen: String?
    /// S7 끝내기·영업일 끝 안내 뒤 여는 하루 기록(S6)
    @State private var openDay: Stats.Day?
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var phase
    /// 강풍 안내·오늘 운영(R34·R35)의 기준 시각. 앞에 있는 동안 5분마다 새로 잡는다(운영 종료·06:00 전환은 최대 5분 늦게 반영).
    @State private var now = Date.now
    @State private var tick = 0
    /// 슬로프 현황·웹캠을 여는 앱 안 브라우저
    @State private var browser: WebPage?
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

    private var startLabel: String {
        guard let id = startResort else { return "시작할 때 리조트를 골라요" }
        return "\(Resort.name(id)) · \(id == Recorder.lastResortId ? "마지막으로 기록한 리조트" : "첫 번째 홈 리조트")"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    warnings
                    today
                    cards
                    #if TESTFLIGHT
                    VStack(alignment: .leading) { ExportSection(recorder: recorder) }
                        .padding(.horizontal, 20).padding(.top, 24)
                    #endif
                }
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(FadeBackground())
            .startBarInset()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: Binding(get: { openDay != nil }, set: { if !$0 { openDay = nil } })) {
                if let openDay { DayDetailView(db: recorder.db, day: openDay) }
            }
        }
        .task(id: reloadKey) { await reload() }
        .task(id: "\(weatherResort?.id ?? "")-\(weatherRetry)-\(tick)") { await loadWeather() }
        // 앞에 있는 동안 5분마다: 기준 시각을 새로 잡고 날씨를 다시 읽는다(캐시 30분이 지났을 때만 새로 받음)
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                now = .now
                tick += 1
                try? await Task.sleep(for: .seconds(300))
            }
        }
        .fullScreenCover(item: $browser) { SafariView(url: $0.url).ignoresSafeArea() }
        .onChange(of: startLabel, initial: true) { startBar?.subtitle = startLabel }
        .onChange(of: startBar?.requests) { if recorder.recording == nil { step = .pick } }
        .onAppear {
            guard !launched else { return }
            launched = true
            if recorder.recording != nil { showRecording = true }
        }
        .onChange(of: recorder.recording?.id) { old, new in
            if old == nil, new != nil { showRecording = true }
        }
        // S4는 S5와 같은 전체 화면에 띄워, 권한이 생겨 시작하면 그 자리에서 S5로 바뀐다. 권한이 이미 있으면 S4 없이.
        .onChange(of: recorder.pendingStart) { _, new in
            if new != nil { if recorder.needsLocation { showRecording = true } } else if recorder.recording == nil { showRecording = false }
        }
        .fullScreenCover(isPresented: $showRecording, onDismiss: recorder.cancelPendingStart) {
            Group {
                if recorder.pendingStart != nil && recorder.recording == nil {
                    PermissionView(recorder: recorder) { showRecording = false }
                } else {
                    RecordingView(recorder: recorder) { showRecording = false }
                }
            }
            // 첫 기록 동의: S4가 떠 있으면 그 위에서(바뀌는 내용이 아니라 바깥 Group에 붙여 S5로 바뀌어도 유지)
            .sheet(isPresented: consentShown(inCover: true), onDismiss: recorder.consentAnswered) { consent }
        }
        // 권한이 이미 있으면 홈 위에서. 시트가 다 닫힌 뒤 시작해야 S5 전체 화면과 겹치지 않는다
        .sheet(isPresented: consentShown(inCover: false), onDismiss: recorder.consentAnswered) { consent }
        .sheet(item: $step, onDismiss: next) { s in
            switch s {
            case .pick: ResortPickSheet(homes: homes) { chosen = $0; step = nil }
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

    private enum StartStep: String, Identifiable { case pick; var id: String { rawValue } }

    /// S3가 닫힌 뒤: 권한(S4) → 첫 기록이면 동의 → 시작
    private func next() {
        guard let id = chosen else { return }
        chosen = nil
        recorder.requestStart(resortId: id)
    }

    private func consentShown(inCover: Bool) -> Binding<Bool> {
        Binding(get: { recorder.awaitingConsent && showRecording == inCover }, set: { _ in })
    }

    /// 답하면 시트를 내리고, 닫힌 뒤(onDismiss) 시작을 잇는다. 저장에 실패해도 기록은 시작한다.
    private var consent: some View {
        ConsentSheet { yes in
            try? Settings.answerConsent(yes, db: recorder.db)
            recorder.awaitingConsent = false
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

    // MARK: 위: 홈 리조트, 설정

    private var header: some View {
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
        .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 10)
    }

    // MARK: 경고 (홈 맨 위, decisions 2026-11-11 S2 v15). 기록 중에는 숨김

    @ViewBuilder private var warnings: some View {
        if recorder.recording == nil {
            VStack(spacing: 12) {
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
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
    }

    // MARK: 오늘: 기준 리조트의 날씨·예상 설질 (카드 없이 배경 위)

    @ViewBuilder private var today: some View {
        if let resort = weatherResort {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(resort.name) · \(HomeData.dayLabel(now))")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                switch weather {
                case .loading:
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 8).fill(Color.surface).frame(width: 150, height: 56)
                        RoundedRectangle(cornerRadius: 8).fill(Color.surface).frame(width: 160, height: 14)
                    }
                    .padding(.vertical, 6).opacity(0.6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(resort.name) 날씨 불러오는 중")
                case .failed:
                    Text("날씨를 불러오지 못했어요").font(.headline).foregroundStyle(Color.primaryText).padding(.top, 6)
                    Button { DebugFailures.weatherFails = false; weatherRetry += 1 } label: {
                        Label("다시 시도", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                            .padding(.horizontal, 18).frame(minHeight: 44)
                            .background(Color.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                case .loaded(let s):
                    NavigationLink {
                        WeatherDetailView(cache: weatherCache, homes: homes, selected: resort.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(WeatherFormat.temp(s.current.temperature))
                                    .font(.system(size: bigSize, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(Color.accentText)
                                Text(s.current.condition).font(.system(size: unitSize, weight: .bold))
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.title3.weight(.semibold))
                                    .foregroundStyle(Color.secondaryText).accessibilityHidden(true)
                            }
                            if let est = SnowForecast.estimate(hours: s.hours, now: now) {
                                HStack(spacing: 4) {
                                    Text("설질 · \(est.level.label)")
                                    ForecastTag()
                                }
                                .font(.subheadline).foregroundStyle(Color.secondaryText)
                            }
                        }
                        .foregroundStyle(Color.primaryText)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    let open = Timetable.today(resortId: resort.id, now: now, timetables: ServerConfig.timetables)
                    if let wind = WindNotice.evaluate(hours: s.hours, now: now, today: open) {
                        windLine(wind)
                    }
                }
                hours(resort)
                Text("Apple Weather · 데이터 출처").font(.caption).foregroundStyle(Color.secondaryText).padding(.top, 4)
            }
            .padding(.horizontal, 20).padding(.bottom, 22)
        }
    }

    /// 강풍 안내 (R35): 바람 강조와 공식 현황 안내. 운휴는 예측하지 않는다.
    private func windLine(_ w: WindNotice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "wind").foregroundStyle(Color.windAmber).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(w.title).fontWeight(.bold).foregroundStyle(Color.primaryText)
                Text(WindNotice.hint).foregroundStyle(Color.secondaryText)
            }
        }
        .font(.subheadline)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    /// 오늘 운영 (R34): 확인된 시간표만 시간을 보이고, 아니면 공식 안내로. 휴장으로 표시하지 않는다.
    @ViewBuilder private func hours(_ resort: Resort) -> some View {
        let open = Timetable.today(resortId: resort.id, now: now, timetables: ServerConfig.timetables) ?? []
        VStack(alignment: .leading, spacing: 4) {
            Text("오늘 운영").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
            if open.isEmpty {
                Text("운영 시간은 공식 안내에서 확인하세요").font(.subheadline).foregroundStyle(Color.secondaryText)
            } else {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                                          : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
                layout {
                    ForEach(open, id: \.interval.start) { o in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.kindLabel(o)).font(.footnote).foregroundStyle(Color.secondaryText)
                            Text("\(o.start)–\(o.end)").font(.callout.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(Color.primaryText)
                        }
                        .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            HStack(spacing: 8) {
                linkButton("슬로프 현황", resort.slopeStatusURL)
                if let cam = resort.webCamURL { linkButton("웹캠", cam) }
            }
            .padding(.top, 6)
        }
        .padding(.top, 12)
    }

    static func kindLabel(_ o: Timetable.Open) -> String {
        let name = switch o.kind { case .day: "주간"; case .night: "야간"; case .lateNight: "심야" }
        return o.nextDay ? "\(name) · 다음 날" : name
    }

    private func linkButton(_ title: String, _ url: URL) -> some View {
        Button { browser = WebPage(url: url) } label: {
            Label(title, systemImage: "arrow.up.right.square")
                .labelStyle(TrailingIcon())
                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                .padding(.horizontal, 16).frame(minHeight: 44)
                .glassCapsule()
        }
        .buttonStyle(.plain)
        .accessibilityHint("앱 안 브라우저에서 열기")
    }

    // MARK: 기록 카드: 최근 기록(오늘 기록) → 이번 시즌 → 시즌권. 기록이 없으면 기록 방법

    private enum Card: Int { case recent, season, pass }

    private var cardList: [Card] {
        var c: [Card] = [.recent, .season]
        if pass != nil { c.append(.pass) }
        return c
    }

    @ViewBuilder private var cards: some View {
        if loaded && days.isEmpty {
            howTo.padding(.horizontal, 16)
        } else if typeSize.isAccessibilitySize {
            // 가장 큰 글씨: 옆으로 넘기지 않고 세로로 쌓는다(v15 큰 글씨 판)
            VStack(spacing: 12) {
                ForEach(cardList, id: \.self) { cardView($0) }
            }
            .padding(.horizontal, 16)
        } else {
            let list = cardList
            VStack(spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(list.enumerated()), id: \.element) { i, card in
                            cardView(card).frame(width: 250).id(i)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $page)

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
        case .recent:
            if let day = days.first(where: \.isVisit) ?? days.first {
                let t = Stats.totals([day])
                let isToday = BusinessDay.same(day.date, .now)
                NavigationLink { DayDetailView(db: recorder.db, day: day) } label: {
                    RecordCard(icon: "clock", label: isToday ? "오늘 기록" : "최근 기록 · \(HomeData.monthDay(day.date))",
                               value: "\(t.runs)회", sub: "\(RecordFormat.km(t.distance)) · 고도차 \(Int(t.drop).formatted())m")
                }
                .buttonStyle(.plain)
            } else {
                RecordCard(icon: "clock", label: "최근 기록", value: "0회", sub: "불러오는 중").redacted(reason: .placeholder)
            }
        case .season:
            let t = Stats.totals(days)
            RecordCard(icon: "chart.bar", label: "이번 시즌", value: "\(t.visitDays)일",
                       sub: "\(t.runs)회 · \(RecordFormat.km(t.distance))")
                .redacted(reason: loaded ? [] : .placeholder)
        case .pass:
            if let pass {
                if let v = pass.value {
                    RecordCard(icon: "ticket", label: pass.label, value: "\(Int(v.perVisit.rounded()).formatted())원", sub: "1회 방문당")
                } else {
                    RecordCard(icon: "ticket", label: pass.label, value: "방문 전", sub: "방문하면 1회 방문당 금액을 계산해요")
                }
            }
        }
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("스키장에 도착하면 아래 기록 시작을 누르세요").font(.headline).foregroundStyle(Color.primaryText)
            ForEach(Array(["리프트 타기 전에 아래 기록 시작", "휴대폰은 주머니에", "다 타면 종료 길게 누르기"].enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1)").fontWeight(.bold).monospacedDigit().foregroundStyle(Color.accentText)
                    Text(s).foregroundStyle(Color.primaryText)
                }
                .font(.subheadline)
            }
        }
        .card()
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
        if case .loaded = weather, weatherFor == resort.id {} else { weather = .loading }
        do {
            let snapshot = try await weatherCache.weather(for: resort)
            if !Task.isCancelled { weather = .loaded(snapshot); weatherFor = resort.id }
        } catch {
            if !Task.isCancelled { weather = .failed }
        }
    }
}

/// 홈 기록 카드 (v15): 제목 블록 아래 큰 숫자 + 보조 줄 블록을 남은 높이의 가운데에. 최소 높이 168
private struct RecordCard: View {
    var icon: String
    var label: String
    var value: String
    var sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                IconCircle(systemName: icon, size: 36)
                Text(label).font(.headline).foregroundStyle(Color.primaryText)
            }
            Spacer(minLength: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.largeTitle.bold()).monospacedDigit().foregroundStyle(Color.accentText)
                Text(sub).font(.subheadline).foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.cardBorder))
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

/// 시즌권 카드 값 (R8): 1장이면 그 시즌권, 여러 장이면 합계.
struct PassSummary {
    var label: String
    var value: PassValue.Value?

    init?(db: AppDatabase, season: String, days: [Stats.Day]) {
        guard let passes = try? db.passes(season: season), let first = passes.first else { return nil }
        let r = PassValue.compute(passes, days: days, season: season)
        if passes.count == 1 {
            label = first.pass.name
            value = r.perPass[first.pass.id] ?? nil
        } else {
            label = "시즌권 \(passes.count)장"
            value = r.total
        }
    }
}

nonisolated extension HomeData {
    /// "2026-27" → 2026-11-01 06:00 (한국)
    static func seasonStart(_ season: String) -> Date {
        let y = Int(season.prefix(4)) ?? 2026
        return seoul.date(from: DateComponents(year: y, month: 11, day: 1, hour: 6))!
    }

    /// 영업일 날짜 "11월 27일 목요일" (06:00 전이면 전날)
    static func dayLabel(_ now: Date) -> String {
        let d = BusinessDay.start(of: now)
        let c = seoul.dateComponents([.month, .day, .weekday], from: d)
        let w = ["일", "월", "화", "수", "목", "금", "토"][(c.weekday ?? 1) - 1]
        return "\(c.month ?? 0)월 \(c.day ?? 0)일 \(w)요일"
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

/// 앱 안 브라우저로 여는 공식 페이지 (R34)
struct WebPage: Identifiable {
    let url: URL
    var id: URL { url }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

/// 글자 뒤에 아이콘 ("슬로프 현황 ↗")
private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon.imageScale(.small) }
    }
}

extension Resort {
    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
}

extension Color {
    /// 기록 시작 캡슐의 원 안 아이콘 (시안: 밝게·어둡게 모두 프로스트)
    static let frost = Color(light: 0x5CE1E6, dark: 0x5CE1E6)
}

extension Color {
    /// 강풍 안내 아이콘 (경고 노랑, StatusBanner와 같은 값)
    static let windAmber = Color(light: 0xA87400, dark: 0xF2C14E)
}

extension View {
    /// 유리 캡슐 (iOS 26). 17.6~25는 보조 면 캡슐.
    @ViewBuilder func glassCapsule() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.background(Color.surface, in: Capsule())
        }
    }

    /// 유리 원 버튼 (iOS 26). 17.6~25는 유리 대신 강조색 아이콘 (B1 v1).
    @ViewBuilder func glassCircle() -> some View {
        if #available(iOS 26, *) {
            self.foregroundStyle(Color.primaryText).glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.foregroundStyle(Color.accentText)
        }
    }
}
