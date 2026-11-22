import SwiftUI

/// 리조트 화면 (R58, 07-visual-design 6장 "R58 확정"). 전체 화면 지도 + 시트(S6와 같은 구조).
/// 가운데 툴바 2D/3D(둘 다 무료, 내 위치 없음). 시트 25%·50%, 처음 2D는 50%, 3D는 25%. 홈 "자세히"·카드·리조트 비교가 연다
struct ResortView: View {
    let db: AppDatabase
    let resortId: String
    let cache: WeatherCache
    @Binding var favorites: [String]

    @Environment(\.colorScheme) private var scheme
    @State private var is3D: Bool
    @State private var detent: PresentationDetent
    @State private var size: CGSize = .zero
    /// 시트 높이. 재기 전에는 detent 비율로 어림
    @State private var sheetSize: CGFloat?
    @State private var showSheet = true
    // 날씨 상세는 시트를 내리고 이 화면 스택에 올린다(S6 하강 상세와 같은 흐름)
    @State private var pendingWeather = false
    @State private var showWeather = false

    init(db: AppDatabase, resortId: String, cache: WeatherCache, favorites: Binding<[String]>, start3D: Bool = false) {
        (self.db, self.resortId, self.cache) = (db, resortId, cache)
        _favorites = favorites
        _is3D = State(initialValue: start3D)
        _detent = State(initialValue: .fraction(0.25))   // 2D 축척이 작은 시트 기준이라 처음엔 리조트 전체가 보이게 작게 연다
    }

    private var resort: Resort? { Resort.all.first { $0.id == resortId } }
    private var map: SlopeMap? { SlopeMap.cached(resortId: resortId).flatMap { $0.isDrawable ? $0 : nil } }
    private var sheetHeight: CGFloat { sheetSize ?? size.height * (detent == .fraction(0.5) ? 0.5 : 0.25) }

    var body: some View {
        Group {
            if let map {
                ResortMapView(map: map, is3D: $is3D, sheetHeight: sheetHeight)
            } else {
                Color.bg.ignoresSafeArea()
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .navigationTitle(Resort.name(resortId))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if let map, Terrain.layer(map, dark: scheme == .dark) != nil {
                ToolbarItem(placement: .principal) {
                    Picker("지도 보기", selection: $is3D) {
                        Text("2D").tag(false)
                        Text("3D").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 136)   // 시안: 한 칸 64pt. fixedSize면 "2D" 글자 폭으로 줄어든다
                }
            }
        }
        .sheet(isPresented: $showSheet, onDismiss: { if pendingWeather { pendingWeather = false; showWeather = true } }) { sheet }
        .navigationDestination(isPresented: $showWeather) { WeatherDetailView(cache: cache, homes: [resortId], selected: resortId) }
        .onChange(of: showWeather) { if !showWeather { showSheet = true } }
        .onChange(of: is3D) { if is3D { detent = .fraction(0.25) } }
    }

    private var sheet: some View {
        ScrollView {
            if let resort {
                ResortInfo(resort: resort, cache: cache, favorite: favorites.contains(resortId), onFavorite: toggleFavorite) {
                    pendingWeather = true
                    showSheet = false
                }
                .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 24)
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetSize = $0 }
        .presentationDetents([.fraction(0.25), .fraction(0.5)], selection: $detent)
        .presentationBackgroundInteraction(.enabled)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .modifier(SheetBackground())
    }

    /// ★: 저장된 즐겨찾기 순서를 지키며 끝에 더하거나 뺀다. 저장에 실패하면 화면도 그대로
    private func toggleFavorite() {
        var ids = (try? db.homeResorts()) ?? favorites
        if let i = ids.firstIndex(of: resortId) { ids.remove(at: i) } else { ids.append(resortId) }
        guard (try? db.setHomeResorts(ids)) != nil else { return }
        favorites = ids
    }
}

/// 리조트 시트 내용 (리조트 화면·S1 미리보기 공통): 이름·지역, ★, 날씨(→ onWeather), 오늘 운영(현황·웹캠), 슬로프, 출처.
/// favorite이 nil이면 ★를 숨긴다(S1 미리보기). 링크는 앱 안 브라우저로
struct ResortInfo: View {
    let resort: Resort
    let cache: WeatherCache
    var favorite: Bool? = nil
    var onFavorite: () -> Void = {}
    let onWeather: () -> Void

    @State private var weather: WeatherLoad = .loading
    @State private var retry = 0
    @State private var browser: WebPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(resort.name).font(.title2.weight(.bold)).foregroundStyle(Color.primaryText)
                    Text(resort.place).font(.subheadline).foregroundStyle(Color.secondaryText)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if let favorite {
                    Button(action: onFavorite) {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(favorite ? Color.accentText : Color.secondaryText)
                            .frame(width: 44, height: 44)
                            .glassCircle()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(favorite ? "즐겨찾기에서 빼기" : "즐겨찾기에 추가")
                }
            }
            weatherLine.padding(.top, 8)
            TodayHours(resort: resort, now: .now) { browser = WebPage(url: $0) }
            slopes.padding(.top, 16)
            Text("Apple Weather · 데이터 출처").font(.caption).foregroundStyle(Color.secondaryText).padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(resort.id)-\(retry)") { await load() }
        // 시트 안에서 띄워야 시트 위에 보인다
        .fullScreenCover(item: $browser) { SafariView(url: $0.url).ignoresSafeArea() }
    }

    @ViewBuilder private var weatherLine: some View {
        switch weather {
        case .loading:
            RoundedRectangle(cornerRadius: 8).fill(Color.surface).frame(width: 160, height: 32).opacity(0.6)
                .accessibilityLabel("\(resort.name) 날씨 불러오는 중")
        case .failed:
            HStack(spacing: 12) {
                Text("날씨를 불러오지 못했어요").font(.subheadline).foregroundStyle(Color.primaryText)
                Button { DebugFailures.weatherFails = false; retry += 1 } label: {
                    Label("다시 시도", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .background(Color.surface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        case .loaded(let s):
            Button(action: onWeather) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(WeatherFormat.temp(s.current.temperature))
                            .font(.title.weight(.bold)).monospacedDigit().foregroundStyle(Color.accentText)
                        Text(s.current.condition).font(.headline)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.secondaryText).accessibilityHidden(true)
                    }
                    if let est = SnowForecast.estimate(hours: s.hours, now: .now) {
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
            .accessibilityHint("날씨 상세 보기")
        }
    }

    @ViewBuilder private var slopes: some View {
        if let counts = DifficultyCounts.of(resort.id), counts.total > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("슬로프 \(counts.total)개 · 지도 기준").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
                DifficultyBar(counts: counts)
                DifficultyLegend(counts: counts)
                if counts.unknown > 0 {
                    Text("난이도 정보 없는 슬로프 \(counts.unknown)개").font(.footnote).foregroundStyle(Color.secondaryText)
                }
            }
        }
    }

    private func load() async {
        if case .loaded = weather {} else { weather = .loading }
        do {
            let s = try await cache.weather(for: resort)
            if !Task.isCancelled { weather = .loaded(s) }
        } catch {
            if !Task.isCancelled { weather = .failed }
        }
    }
}

/// S1 미리보기 (R58 v1): S1 위 큰 시트. 닫기, 작은 2D/3D 지도, ResortInfo(★ 없음), 아래 고정 즐겨찾기 버튼
struct ResortPreviewSheet: View {
    let resortId: String
    let cache: WeatherCache
    let picked: Bool
    let toggle: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var is3D = false
    @State private var snapshot: UIImage?
    @State private var snapshotDone = false
    @State private var showWeather = false

    private var resort: Resort? { Resort.all.first { $0.id == resortId } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let map = SlopeMap.cached(resortId: resortId), map.isDrawable { thumbnail(map) }
                    if let resort {
                        ResortInfo(resort: resort, cache: cache) { showWeather = true }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(Color.bg)
            .navigationTitle(Resort.name(resortId))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("닫기")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: toggle) {
                    Text(picked ? "즐겨찾기에서 빼기" : "즐겨찾기에 추가")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent).tint(Color.accentFill).foregroundStyle(Color.onAccent)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.bg)
            }
            .navigationDestination(isPresented: $showWeather) { WeatherDetailView(cache: cache, homes: [resortId], selected: resortId) }
        }
    }

    private func thumbnail(_ map: SlopeMap) -> some View {
        VStack(spacing: 8) {
            Picker("지도 보기", selection: $is3D) {
                Text("2D").tag(false)
                Text("3D").tag(true)
            }
            .pickerStyle(.segmented)
            ZStack {
                if is3D {
                    if let snapshot {
                        // 아래 84pt는 홈 카드 캡션 자리라 위쪽을 맞춰 자른다
                        Image(uiImage: snapshot).resizable().scaledToFill()
                            .frame(maxHeight: .infinity, alignment: .top)
                            .accessibilityLabel("\(Resort.name(resortId)) 3D 지형 지도")
                    } else if snapshotDone {
                        Text("3D 지도를 준비하지 못했어요").font(.subheadline).foregroundStyle(Color.secondaryText)
                    } else {
                        ProgressView().accessibilityLabel("3D 준비 중")
                    }
                } else {
                    ResortMapThumbnail(map: map)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 200)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding(.top, 8)
        .task(id: is3D) {
            guard is3D, !snapshotDone else { return }
            snapshot = await Resort3DSnapshot.image(resortId: resortId)
            snapshotDone = true
        }
    }
}

#Preview("리조트 화면") {
    NavigationStack {
        if let db = try? AppDatabase(path: ":memory:") {
            ResortView(db: db, resortId: "high1", cache: WeatherCache(), favorites: .constant(["high1"]))
        }
    }
}

#Preview("S1 미리보기") {
    Color.bg.sheet(isPresented: .constant(true)) {
        ResortPreviewSheet(resortId: "yongpyong", cache: WeatherCache(), picked: false) {}
    }
}
