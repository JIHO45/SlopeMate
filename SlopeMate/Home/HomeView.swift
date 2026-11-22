import SafariServices
import SwiftUI
import UIKit

/// 홈 (R58 홈 v3, S2 v15를 대체). 맨 위 리조트 드롭다운·비교·설정, 고른 리조트의 오늘, 리조트 카드 4장.
/// 기록 시작 캡슐(RootView의 StartBar)을 누르면 여기서 S3를 연다.
struct HomeView: View {
    @Bindable var recorder: Recorder
    @State private var homes: [String] = []
    @State private var days: [Stats.Day] = []
    @State private var passes: [(pass: SeasonPass, resorts: [String])] = []
    @State private var loaded = false
    @State private var lowStorage = false
    /// 리조트 화면·리조트 비교와 같이 쓴다
    @State private var weatherCache = WeatherCache()
    @State private var weather: WeatherLoad = .loading
    @State private var weatherRetry = 0
    /// 지금 보이는 날씨의 리조트. 같은 리조트를 다시 읽을 때만 이전 값을 두고, 바뀌면 '불러오는 중'으로
    @State private var weatherFor: String?
    @State private var page: Int? = 0
    @State private var snapshot: UIImage?
    @Binding var showRecording: Bool
    /// S1이 떠 있는지. 닫히면 즐겨찾기·날씨·시작 기본값을 다시 읽는다.
    var setupShown = false
    /// 탭 막대 위 기록 시작 캡슐: 누른 횟수가 바뀌면 S3, 보조 줄(고른 리조트 이름)은 여기서 정한다
    @Environment(StartBarModel.self) private var startBar: StartBarModel?
    /// 앱을 켰을 때 이어지는 기록이면 한 번만 S5를 연다. 탭을 오갈 때는 다시 열지 않는다.
    @State private var launched = false
    @State private var settingsEdits = 0
    /// S3 시트
    @State private var step: StartStep?
    /// S3에서 고른 리조트. 시트가 닫힌 뒤 권한(S4) → 동의(첫 기록) → 시작으로 넘긴다(Recorder.requestStart).
    @State private var picked: String?
    /// 홈 메뉴에서 고른 리조트(R58). 기록을 시작해도 바뀐다(Recorder.start)
    @AppStorage("chosenResortId") private var chosenResort: String?
    /// S7 끝내기·영업일 끝 안내 뒤 여는 하루 기록(S6)
    @State private var openDay: Stats.Day?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    /// 강풍 안내·오늘 운영(R34·R35)의 기준 시각. 앞에 있는 동안 5분마다 새로 잡는다(운영 종료·06:00 전환은 최대 5분 늦게 반영).
    @State private var now = Date.now
    @State private var tick = 0
    /// 슬로프 현황·웹캠을 여는 앱 안 브라우저
    @State private var browser: WebPage?
    @ScaledMetric(relativeTo: .largeTitle) private var bigSize = 64
    @ScaledMetric(relativeTo: .title) private var unitSize = 28

    /// 고른 리조트 = 홈·기록 시작 기본값 (R58, R1). 메뉴에서 고른 리조트, 없으면 마지막 기록·첫 즐겨찾기
    private var resortId: String? {
        AppDatabase.defaultResort(homes: homes, last: Recorder.lastResortId, chosen: chosenResort)
    }

    private var resort: Resort? {
        resortId.flatMap { id in Resort.all.first { $0.id == id } }
    }

    private var startLabel: String { resort?.name ?? "시작할 때 리조트를 골라요" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    warnings
                    if let resort {
                        today(resort)
                        cards(resort.id)
                    } else {
                        Text("위에서 리조트를 고르면 날씨와 지도를 보여드려요")
                            .font(.headline).foregroundStyle(Color.secondaryText)
                            .padding(.horizontal, 20).padding(.top, 12)
                    }
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
            // 리조트 화면·비교에서 돌아오면 즐겨찾기를 다시 읽는다
            .onAppear { if loaded, let h = try? recorder.db.homeResorts() { homes = h } }
            .navigationDestination(isPresented: Binding(get: { openDay != nil }, set: { if !$0 { openDay = nil } })) {
                if let openDay { DayDetailView(db: recorder.db, day: openDay) }
            }
        }
        .task(id: reloadKey) { await reload() }
        .task(id: "\(resortId ?? "")-\(weatherRetry)-\(tick)") { await loadWeather() }
        .task(id: resortId) {
            snapshot = nil
            page = 0
            if let resortId { snapshot = await Resort3DSnapshot.image(resortId: resortId) }
        }
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
            case .pick: ResortPickSheet(homes: homes, preferred: resortId) { picked = $0; step = nil }
            }
        }
        .sheet(item: resumePrompt) { p in
            ResumeSheet(db: recorder.db, prompt: p) {
                recorder.answerResume(true)
            } end: {
                guard case .resume(let rec) = p else { return }
                recorder.answerResume(false)
                // 묻는 동안 06:00이 지났으면 영업일 끝 안내가 대신 뜬다
                if recorder.dayEndNotice?.id != rec.id { showDay(of: rec) }
            } openDay: {
                guard case .dayEnd(let rec) = p else { return }
                recorder.acknowledgeDayEnd()
                showDay(of: rec)
            }
        }
    }

    /// 막 끝낸 기록은 캐시가 아직 없을 수 있어(판정이 위치점 전체를 돈다) 메인 밖에서 찾는다
    private func showDay(of rec: Recording) {
        let db = recorder.db
        Task { openDay = await Task.detached(priority: .userInitiated) { db.day(of: rec) }.value }
    }

    private enum StartStep: String, Identifiable { case pick; var id: String { rawValue } }

    /// S3가 닫힌 뒤: 권한(S4) → 첫 기록이면 동의 → 시작
    private func next() {
        guard let id = picked else { return }
        picked = nil
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

    private func resortView(_ id: String, start3D: Bool = false) -> ResortView {
        ResortView(db: recorder.db, resortId: id, cache: weatherCache, favorites: $homes, start3D: start3D)
    }

    // MARK: 위: 리조트 드롭다운, 비교, 설정

    private var header: some View {
        let others = Resort.all.map(\.id).filter { !homes.contains($0) }.sorted { Resort.name($0) < Resort.name($1) }
        return HStack(spacing: 8) {
            // 인라인 Picker 안 Section은 메뉴에 구역 제목이 안 보여 Toggle(메뉴에서 체크 표시)로 그린다
            Menu {
                if !homes.isEmpty { resortSection("★ 즐겨찾기", homes) }
                resortSection("다른 리조트", others)
            } label: {
                HStack(spacing: 6) {
                    Text(resort?.name ?? "리조트 고르기").lineLimit(1)
                    Image(systemName: "chevron.down").font(.footnote.weight(.bold)).accessibilityHidden(true)
                }
                .font(.headline).foregroundStyle(Color.primaryText)
                .padding(.horizontal, 16).frame(minHeight: 44)
                .glassCapsule()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(resort.map { "리조트: \($0.name)" } ?? "리조트 고르기")
            NavigationLink {
                ResortCompareView(db: recorder.db, cache: weatherCache, favorites: $homes)
            } label: {
                Label("비교", systemImage: "tablecells")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .glassCapsule()
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
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

    private func resortSection(_ title: String, _ ids: [String]) -> some View {
        Section(title) {
            ForEach(ids, id: \.self) { id in
                Toggle(Resort.name(id), isOn: Binding(get: { id == resortId }, set: { if $0 { chosenResort = id } }))
            }
        }
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

    // MARK: 오늘: 고른 리조트의 날씨·예상 설질 (카드 없이 배경 위)

    private func today(_ resort: Resort) -> some View {
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
                NavigationLink { resortView(resort.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(WeatherFormat.temp(s.current.temperature))
                                .font(.system(size: bigSize, weight: .bold)).monospacedDigit()
                                .foregroundStyle(Color.accentText)
                            Text(s.current.condition).font(.system(size: unitSize, weight: .bold))
                            Spacer(minLength: 0)
                            Text("자세히 \(Image(systemName: "chevron.right"))").font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.secondaryText)
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
            TodayHours(resort: resort, now: now) { browser = WebPage(url: $0) }
            Text("Apple Weather · 데이터 출처").font(.caption).foregroundStyle(Color.secondaryText).padding(.top, 4)
        }
        .padding(.horizontal, 20).padding(.bottom, 22)
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

    // MARK: 카드: 고른 리조트의 3D 지도 → 슬로프 → 내 기록 → 시즌권(있을 때만)

    private enum Card: Int { case map, slopes, visits, pass }

    private func cards(_ id: String) -> some View {
        let pass = PassSummary.forResort(id, passes: passes, days: days, season: HomeData.currentSeason())
        let list: [Card] = pass == nil ? [.map, .slopes, .visits] : [.map, .slopes, .visits, .pass]
        return VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(list.enumerated()), id: \.element) { i, card in
                        cardView(card, id, pass).frame(width: 318).id(i)
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

    @ViewBuilder private func cardView(_ card: Card, _ id: String, _ pass: PassSummary?) -> some View {
        switch card {
        case .map:
            NavigationLink { resortView(id, start3D: true) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("3D 지도").font(.headline)
                    Text("돌려 보며 슬로프 찾기").font(.subheadline).foregroundStyle(Color.secondaryText)
                }
                .foregroundStyle(Color.primaryText)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassPanel()
                // 3D 그림은 어둡게에서도 밝은 그림이라 캡션도 밝게
                .environment(\.colorScheme, .light)
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 240, alignment: .bottomLeading)
                .background {
                    if let snapshot {
                        Image(uiImage: snapshot).resizable().scaledToFill()
                    } else {
                        Color.surface
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.cardBorder))
                .contentShape(RoundedRectangle(cornerRadius: 24))
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
        case .slopes:
            if let c = DifficultyCounts.of(id) {
                NavigationLink { resortView(id) } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            IconCircle(systemName: "mountain.2", size: 36)
                            Text("슬로프").font(.headline).foregroundStyle(Color.primaryText)
                            Spacer(minLength: 4)
                            Text("지도 기준").font(.footnote).foregroundStyle(Color.secondaryText)
                        }
                        Text("\(c.total)개").font(.largeTitle.bold()).monospacedDigit().foregroundStyle(Color.accentText)
                            .padding(.leading, -2)   // 큰 글자 왼쪽 글꼴 여백만큼 당겨 아래 줄과 맞춤
                            .padding(.top, 16)
                        // 9개는 제목 아래에 두고, 막대·범례 묶음은 남는 높이의 위아래를 같게(사용자 2026-11-22)
                        Spacer(minLength: 16)
                        DifficultyBar(counts: c)
                        DifficultyLegend(counts: c).padding(.top, 10)
                        if c.unknown > 0 {
                            Text("난이도 정보 없는 슬로프 \(c.unknown)개").font(.footnote).foregroundStyle(Color.secondaryText)
                                .padding(.top, 4)
                        }
                        Spacer(minLength: 16)
                    }
                    .homeCard()
                }
                .buttonStyle(.plain)
            }
        case .visits:
            visitsCard(id)
        case .pass:
            if let pass {
                if let v = pass.value {
                    RecordCard(icon: "ticket", label: pass.label, caption: "1회 방문당", value: "\(Int(v.perVisit.rounded()).formatted())원", sub: nil,
                               stats: [("가격", "\(v.price.formatted())원"), ("방문", "\(v.visits)일")]
                                   + (pass.ticket.map { [("리프트권이었다면", "\($0.formatted())원")] } ?? []))
                } else {
                    RecordCard(icon: "ticket", label: pass.label, caption: "방문하면 1회 방문당 금액을 계산해요", value: "방문 전", sub: nil)
                }
            }
        }
    }

    /// ③ 이 리조트 내 기록: 이번 시즌 방문일 + 최근 기록 한 줄 → S6(기록 중인 오늘은 S5)
    @ViewBuilder private func visitsCard(_ id: String) -> some View {
        let mine = days.filter { $0.resortId == id }
        let label = "\(Resort.name(id)) 내 기록"
        let visits = "\(Stats.totals(mine).visitDays)일"
        if let day = mine.first(where: \.isVisit) ?? mine.first {
            let isToday = BusinessDay.same(day.date, .now)
            let season = Stats.totals(mine)
            // 240 높이에 합계 칸까지 넣으려고 최근 날짜는 머리말로, 보조 줄은 뺀다(카드를 누르면 그날로)
            let card = RecordCard(icon: "clock", label: label, caption: "이번 시즌 · 최근 \(isToday ? "오늘" : HomeData.monthDay(day.date))", value: visits,
                                  sub: nil,
                                  stats: [("런", "\(season.runs)회"), ("거리", RecordFormat.km(season.distance)), ("최고 속도", RecordFormat.kmh(season.maxSpeed))])
            // 기록 중인 하루는 S6가 끝난 기록만 읽어 비어 보인다. 기록 화면(S5)으로
            if isToday, recorder.recording?.resortId == day.resortId {
                Button { showRecording = true } label: { card }.buttonStyle(.plain)
            } else {
                NavigationLink { DayDetailView(db: recorder.db, day: day) } label: { card }.buttonStyle(.plain)
            }
        } else {
            RecordCard(icon: "clock", label: label, caption: "이번 시즌", value: "0일", sub: "스키장에 도착하면 아래 기록 시작을 누르세요")
                .redacted(reason: loaded ? [] : .placeholder)
        }
    }

    // MARK: 불러오기

    private func reload() async {
        homes = (try? recorder.db.homeResorts()) ?? []
        lowStorage = Recorder.lowStorage
        let db = recorder.db, s = HomeData.currentSeason()
        days = await Task.detached(priority: .userInitiated) {
            Stats.days((try? HomeData.days(db, since: HomeData.seasonStart(s))) ?? [], inSeason: s)
        }.value
        passes = (try? db.passes(season: s)) ?? []
        loaded = true
    }

    private func loadWeather() async {
        guard let resort else { return }
        if case .loaded = weather, weatherFor == resort.id {} else { weather = .loading }
        do {
            let snapshot = try await weatherCache.weather(for: resort)
            if !Task.isCancelled { weather = .loaded(snapshot); weatherFor = resort.id }
        } catch {
            if !Task.isCancelled { weather = .failed }
        }
    }
}

/// 홈 카드 (R58 v3): 폭 318(밖에서), 최소 높이 240, 안쪽 여백 20
private extension View {
    func homeCard() -> some View {
        self.padding(20)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.cardBorder))
            .contentShape(RoundedRectangle(cornerRadius: 24))
            .accessibilityElement(children: .combine)
    }

    /// 유리 캡션 (iOS 26). 17.6~25는 흐린 재질
    @ViewBuilder func glassPanel() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// 홈 기록 카드: 제목 바로 아래 16에 큰 숫자(+ 그 아래 머리말), 합계 칸·보조 줄은 남는 높이의 가운데
private struct RecordCard: View {
    var icon: String
    var label: String
    var caption: String?
    var value: String
    var sub: String?
    /// 이번 시즌 합계 칸(이름, 값). 슬로프 카드 막대·범례 자리
    var stats: [(String, String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                IconCircle(systemName: icon, size: 36)
                Text(label).font(.headline).foregroundStyle(Color.primaryText)
            }
            VStack(alignment: .leading, spacing: 2) {
                // 큰 숫자를 맨 위에(슬로프 카드 9개와 같은 높이), 머리말은 그 아래
                Text(value).font(.largeTitle.bold()).monospacedDigit().foregroundStyle(Color.accentText)
                    .padding(.leading, -2)   // 큰 글자 왼쪽 글꼴 여백만큼 당겨 머리말·합계 칸과 맞춤
                if let caption { Text(caption).font(.subheadline).foregroundStyle(Color.secondaryText) }
            }
            .padding(.top, 16)
            // 슬로프 카드처럼 큰 숫자 아래 남는 높이의 가운데에 보조 줄(사용자 2026-11-22)
            Spacer(minLength: 16)
            if !stats.isEmpty {
                // 큰 숫자보다 한참 작게, 칸 사이는 같은 간격으로 왼쪽부터(슬로프 범례처럼)
                HStack(alignment: .top, spacing: 24) {
                    ForEach(stats, id: \.0) { name, v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Color.primaryText)
                            Text(name).font(.footnote).foregroundStyle(Color.secondaryText)
                        }
                    }
                }
            }
            if let sub { Text(sub).font(.subheadline).foregroundStyle(Color.secondaryText) }
            Spacer(minLength: 16)
        }
        .homeCard()
    }
}

/// 시즌권 카드 값 (R8)
nonisolated struct PassSummary: Equatable {
    var label: String
    var value: PassValue.Value?
    /// 리프트권으로 샀다면 쓴 금액(시즌권 화면과 같은 값)
    var ticket: Int? = nil

    /// 이 리조트 시즌권 (R58 홈 ④): 이 리조트를 포함하는 시즌권 중 순서가 가장 앞인 것의 1회 방문당. 없으면 nil
    static func forResort(_ resortId: String, passes: [(pass: SeasonPass, resorts: [String])], days: [Stats.Day], season: String) -> PassSummary? {
        guard let p = passes.filter({ $0.pass.season == season && $0.resorts.contains(resortId) })
                .min(by: { $0.pass.sortOrder < $1.pass.sortOrder }) else { return nil }
        let r = PassValue.compute(passes, days: days, season: season)
        let v = r.perPass[p.pass.id] ?? nil
        return PassSummary(label: p.pass.name, value: v, ticket: v == nil ? nil : r.ticketValue[p.pass.id])
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
