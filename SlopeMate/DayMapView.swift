import SwiftUI

/// S6 하루 기록 지도형 (v3, 하강 0회 v1; R50). 전체 화면 지도 + 닫히지 않는 아래 시트(약 25%·50%, 뒤 지도 조작 가능).
/// 지도는 내장 OSM으로 기기 안에서 그린다(MapKit·타일 없음). 시트 높이가 바뀌면 시트 위 보이는 영역에 맞춰 중심만 옮긴다.
struct DayMapView: View {
    let db: AppDatabase
    let day: Stats.Day
    let map: SlopeMap
    /// 읽기 전 nil: 슬로프·리프트만 그린다
    let data: DayData?
    let gaps: [Gap]
    let ratings: [Int: SnowRating]
    let span: (Date, Date)?

    @Environment(\.colorScheme) private var scheme
    @Environment(SeasonTicket.self) private var ticket
    /// 툴바 버튼 동작은 예전 화면 값을 잡고 있을 수 있어 상태로 둔다(동영상 색). 처음 onChange 전에는 scheme
    @State private var darkState: Bool?
    private var dark: Bool { darkState ?? (scheme == .dark) }
    @State private var detent: PresentationDetent
    @State private var size: CGSize = .zero
    /// 시트 높이. 재기 전에는 detent 비율로 어림
    @State private var sheetSize: CGFloat?
    // 확대·이동
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    // 3D 보기: 열 때마다 2D, 선택은 기억하지 않는다. 장면은 처음 켤 때 만들고 S6가 열려 있는 동안 둔다
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var is3D = false
    @State private var scene3D: Map3DScene?
    /// 만든 3D 지형. S19가 다시 쓴다(경로와 상관없음)
    @State private var prepared3D: (space: Terrain3D, terrain: Map3DTerrain)?
    @State private var preparing3D = false
    /// 3D가 미리 그리기를 끝냄(onReady). 그 전까지 2D를 보이고, 그때 겹쳐 바꾼다
    @State private var ready3D = false
    /// 장면을 만든 뒤 한 번 보였음. 첫 표시만 날아 들어온다
    @State private var flownIn = false
    // 지도 표시 메뉴(리조트·날짜와 상관없이 기기에 기억)와 누른 슬로프 말풍선
    @AppStorage("mapShowSlopes") private var showSlopes = true
    @AppStorage("mapShowLifts") private var showLifts = true
    @State private var picked: SlopePick.Hit?
    @State private var balloonSize: CGSize = .zero
    // 재생
    @State private var progress = 0.0
    @State private var playing = false
    @State private var started = false
    @State private var selected: Int?
    // 공유
    @AppStorage("shareNoticeShown") private var noticeShown = false
    @State private var notice = false
    @State private var showMaking = false
    @State private var making: Task<Void, Never>?
    @State private var makeProgress = 0.0
    @State private var thumb: UIImage?
    @State private var failed = false
    // 시즌 이용권 잠금(R54): 3D·동영상 고화질·하강 상세. 잠긴 기능을 눌러 산 뒤 S18이 닫히면 그 기능으로 이어 간다
    @State private var showTicket = false
    @State private var pastNote = false
    private enum Resume { case threeD, detail(Int) }
    @State private var resume: Resume?
    // S19 하강 상세(R52): S6 시트를 내린 뒤 밀어 넣고, 돌아오면 다시 올린다(decisions 2026-11-15)
    @State private var showSheet = true
    @State private var pendingDetail: Int?
    @State private var detail: Int?

    init(db: AppDatabase, day: Stats.Day, map: SlopeMap, data: DayData?, gaps: [Gap], ratings: [Int: SnowRating], span: (Date, Date)?) {
        (self.db, self.day, self.map, self.data, self.gaps, self.ratings, self.span) = (db, day, map, data, gaps, ratings, span)
        _detent = State(initialValue: day.runs.isEmpty ? .fraction(0.5) : .fraction(0.25))
    }

    /// 하강 0회면 경로·재생·공유 없이 슬로프·리프트만
    private var hasRuns: Bool { !day.runs.isEmpty }
    private var clock: PlayClock { data?.clock ?? PlayClock([]) }
    private var layers: MapLayers { MapLayers(slopes: showSlopes, lifts: showLifts) }
    private var drawing: DayMapDrawing {
        DayMapDrawing(map: map, route: hasRuns ? data?.route ?? [] : [], dark: dark,
                      terrain: Terrain.layer(map, dark: dark), layers: layers)
    }
    /// 재생을 시작하거나 옮기기 전에는 nil(경로 전체를 진하게)
    private var now: Date? { started ? clock.time(at: progress) : nil }
    private var playingRun: Int? { now.flatMap { t in day.runs.firstIndex { $0.start <= t && t <= $0.end } } }
    private var title: String { "\(RecordFormat.monthDay(day.date)) · \(Resort.name(day.resortId))" }
    private var small: Bool { detent == .fraction(0.25) }
    private var sheetHeight: CGFloat { sheetSize ?? size.height * (detent == .fraction(0.5) ? 0.5 : 0.25) }
    private var lock: SeasonRecap.Lock { Self.lock(day: day.date, owned: ticket.seasons) }

    /// 그 하루 기록 시즌의 이용권으로 연다(decisions 2026-11-14). 시즌 밖 날짜(5~10월)는 이번 시즌으로 본다
    static func lock(day: Date, owned: Set<String>, now: Date = .now) -> SeasonRecap.Lock {
        let current = SeasonTicket.season(purchase: now)
        return SeasonRecap.lock(season: Stats.season(of: day) ?? current, owned: owned, current: current)
    }

    var body: some View {
        ZStack {
            // 3D는 미리 그리기가 끝날 때까지 투명하게 깔고 2D를 보이다가 겹쳐 바꾼다
            if !(is3D && ready3D) { canvas.transition(.opacity) }
            if is3D, let scene3D {
                Map3DView(scene: scene3D, now: now, highlight: (selected ?? playingRun).map { day.runs[$0] }, dark: dark,
                          bottomInset: sheetHeight + 24, reduceMotion: reduceMotion,
                          layers: layers, flyIn: !flownIn && !reduceMotion,
                          onReady: { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { ready3D = true } },
                          onTap: { picked = showSlopes ? $0 : nil })
                    .ignoresSafeArea()
                    .opacity(ready3D ? 1 : 0)
                    .accessibilityElement()
                    .accessibilityLabel("\(Resort.name(day.resortId)) 3D 지형 지도\(hasRuns ? " 위 오늘 경로" : "")")
                    .accessibilityHidden(!ready3D)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .overlay { balloon }
        .overlay(alignment: .bottomTrailing) {
            Text(drawing.terrain == nil ? "© OpenStreetMap" : "© OpenStreetMap · Copernicus DEM").font(.caption).foregroundStyle(Color.secondaryText)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge) // 출처 표시가 지도를 가리지 않게
                .padding(.trailing, 16).padding(.bottom, sheetHeight + 8)
                .ignoresSafeArea()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { layersMenu }
            if data != nil, drawing.terrain != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    if preparing3D {
                        ProgressView().accessibilityLabel("3D 준비 중")
                    } else if lock == .open {
                        Button(action: toggle3D) { Image(systemName: is3D ? "view.2d" : "view.3d") }
                            .accessibilityLabel(is3D ? "2D로 보기" : "3D로 보기")
                    } else {
                        // 잠금 표시 S6 v1: 오른쪽 위 모서리에 걸친 18pt 자물쇠 배지
                        Button { resume = .threeD; unlock() } label: {
                            Image(systemName: "view.3d").overlay(alignment: .topTrailing) {
                                Image(systemName: "lock").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.secondaryText)
                                    .frame(width: 18, height: 18)
                                    .background(Color.card, in: Circle())
                                    .overlay(Circle().strokeBorder(Color.cardBorder))
                                    .offset(x: 13, y: -13)
                            }
                        }
                        .accessibilityLabel("3D로 보기, 시즌 이용권 필요")
                    }
                }
            }
            if hasRuns, data != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    // 공유 고르기 v1: 이미지(R31)·동영상(R50)
                    Menu {
                        Button { playing = false; ShareImage.share(day) } label: {
                            Label { Text("이미지"); Text("오늘 요약 한 장, 경로 없음") } icon: { Image(systemName: "photo") }
                        }
                        Button { noticeShown ? make() : (notice = true) } label: {
                            Label { Text("동영상"); Text("오늘 경로 재생\(is3D ? "(2D 지도)" : ""), \(ShareVideo.seconds)초") } icon: { Image(systemName: "video") }
                        }
                        if lock == .ticket {
                            Divider()
                            Button { resume = nil; unlock() } label: {
                                Label("이용권: 고화질·워터마크 없이", systemImage: "lock")
                            }
                        }
                    } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("공유")
                }
            }
        }
        .sheet(isPresented: $showSheet, onDismiss: { if let i = pendingDetail { pendingDetail = nil; detail = i } }) { sheet }
        .navigationDestination(item: $detail) { i in RunDetailView(db: db, day: day, index: i, route: data?.route ?? [], map: map, prepared3D: prepared3D) }
        .onChange(of: detail) { if detail == nil { showSheet = true } }
        .task(id: playing) { await play() }
        .onChange(of: progress) { follow() }
        // 보는 중 잠기면(환불 등) 3D는 2D로, S19는 닫기
        .onChange(of: lock) {
            guard lock != .open else { return }
            if is3D { switch3D(false) }
            detail = nil
        }
        .onChange(of: scheme, initial: true) { darkState = scheme == .dark }
        // 경로가 바뀌면(다시 읽기) 3D 장면은 다음에 켤 때 다시 만든다
        .onChange(of: data?.route) { detail = nil; is3D = false; ready3D = false; scene3D = nil; flownIn = false; picked = nil }
        // 말풍선은 화면 좌표에 고정: 지도가 움직이면(손짓·따라가기·시트 높이) 닫는다. 슬로프를 끄면 닫는다
        .onChange(of: [zoom, pinch, pan.width, pan.height, drag.width, drag.height, sheetHeight]) { picked = nil }
        .onChange(of: showSlopes) { if !showSlopes { picked = nil } }
        .onDisappear { making?.cancel() }
    }

    /// 2D 지도 층. 한 번 누르기 = 슬로프 이름(끌기는 10pt 움직여야 시작해 겹치지 않는다)
    private var canvas: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let fit = fitRect(size)
                let d = drawing, t = transform(fit), now = now, h = selected.map { day.runs[$0] }
                ctx.withCGContext { cg in d.draw(cg, size: size, MapProjection(map, rect: fit), transform: t, now: now, highlight: h) }
            }
            .gesture(MagnifyGesture()
                .updating($pinch) { v, s, _ in s = v.magnification }
                .onEnded { zoom = min(max(zoom * $0.magnification, 1), 8) }
                .simultaneously(with: DragGesture()
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onEnded { pan.width += $0.translation.width; pan.height += $0.translation.height }))
            .simultaneousGesture(SpatialTapGesture().onEnded { pick($0.location, in: geo.size) })
        }
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel("\(Resort.name(day.resortId)) 전체 슬로프 지도\(hasRuns ? " 위 오늘 경로" : "")")
    }

    /// 누른 자리 22pt 안의 가장 가까운 슬로프. 없거나 슬로프를 꺼 두면 말풍선을 닫는다
    private func pick(_ p: CGPoint, in size: CGSize) {
        guard showSlopes else { picked = nil; return }
        let fit = fitRect(size), proj = MapProjection(map, rect: fit), t = transform(fit)
        picked = SlopePick.nearest(to: p, in: map) { proj.point($0[0], $0[1]).applying(t) }
    }

    /// 말풍선: 누른 선 위 12pt, 좌우 16pt 안. 지도(2D Canvas·3D SCNView)와 같은 화면 전체 좌표
    private var balloon: some View {
        GeometryReader { geo in
            if let picked {
                let w = balloonSize.width, h = balloonSize.height
                SlopeBalloon(hit: picked)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { balloonSize = $0 }
                    .position(x: min(max(picked.anchor.x, 16 + w / 2), geo.size.width - 16 - w / 2),
                              y: picked.anchor.y - 12 - h / 2)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// 지도 표시 메뉴 v1: 슬로프·리프트 켬·끔과 난이도 범례. 이용권·고도 파일과 상관없다
    private var layersMenu: some View {
        Menu {
            Toggle("슬로프", isOn: $showSlopes)
            Toggle("리프트", isOn: $showLifts)
            Section("난이도") {
                ForEach(SlopeStyle.Level.allCases, id: \.self) { level in
                    let word = SlopeStyle.label(level) ?? "정보 없음"
                    Label { Text(word) } icon: { Image(uiImage: Self.legendDot(level, dark: dark)) }
                        .accessibilityLabel("난이도 색 \(word)")
                }
            }
        } label: { Image(systemName: "map") }
            .accessibilityLabel("지도 표시")
    }

    /// 범례 색 점. 메뉴가 아이콘을 한 색으로 칠하지 않게 원래 색으로
    private static func legendDot(_ level: SlopeStyle.Level, dark: Bool) -> UIImage {
        let hex = SlopeStyle.hex(level, dark: dark)
        let casing = SlopeStyle.casing(level, dark: dark)
        func ui(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { ctx in
            let r = CGRect(x: 1, y: 1, width: 10, height: 10)
            ui(hex).setFill()
            ctx.cgContext.fillEllipse(in: r)
            if let casing {
                ui(casing).setStroke()
                ctx.cgContext.setLineWidth(1)
                ctx.cgContext.strokeEllipse(in: r.insetBy(dx: 0.5, dy: 0.5))
            }
        }.withRenderingMode(.alwaysOriginal)
    }

    // MARK: 3D 보기

    /// 잠긴 기능: 이번 시즌은 S18, 사지 않은 지난 시즌은 안내만(지난 시즌 이용권은 팔지 않음)
    private func unlock() {
        playing = false
        if lock == .pastSeason { pastNote = true } else { showTicket = true }
    }

    /// "자세히": 열려 있으면 S6 시트를 내린 뒤(onDismiss) S19, 잠겨 있으면 S18·지난 시즌 안내
    private func openDetail(_ i: Int) {
        playing = false
        guard lock == .open else { resume = .detail(i); return unlock() }
        pendingDetail = i
        showSheet = false
    }

    /// S18이 닫혔을 때 사서 열렸으면 누른 기능으로
    private func resumeAfterTicket() {
        defer { resume = nil }
        guard lock == .open else { return }
        switch resume {
        case .threeD: toggle3D()
        case .detail(let i): openDetail(i)
        case nil: break
        }
    }

    /// 처음 켤 때 지형 메시를 메인 스레드 밖에서 만들고(그동안 2D 그대로), 장면은 MainActor에서
    private func toggle3D() {
        if is3D || scene3D != nil { return switch3D(!is3D) }
        guard !preparing3D, size != .zero, let terrain = drawing.terrain?.terrain else { return }
        preparing3D = true
        let map = map, route = hasRuns ? data?.route ?? [] : [], dark = dark, size = size
        Task {
            let (space, prepared) = await Task.detached(priority: .userInitiated) {
                let space = Terrain3D(terrain: terrain, map: map)
                return (space, Map3DTerrain(space: space, map: map))
            }.value
            // 준비 중 경로가 바뀌면(다시 읽기) 결과를 버린다
            prepared3D = (space, prepared)
            guard route == (hasRuns ? data?.route ?? [] : []) else { preparing3D = false; return }
            scene3D = Map3DScene(space: space, terrain: prepared, map: map, route: route, dark: dark, viewport: size,
                                  view3D: Resort.all.first { $0.id == day.resortId }?.view3D)
            preparing3D = false
            switch3D(true)
        }
    }

    /// 켤 때는 3D를 투명하게 깔기만 하고 onReady에서 겹쳐 바꾼다. 끌 때 바로 2D로
    private func switch3D(_ on: Bool) {
        picked = nil
        if on { return is3D = true }
        if ready3D { flownIn = true }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { is3D = false; ready3D = false }
    }

    // MARK: 지도 위치

    private func fitRect(_ size: CGSize) -> CGRect { Self.fitRect(size, sheetHeight: sheetHeight) }

    /// 리조트 전체가 들어갈 영역. 크기(축척)는 25% 시트 기준으로 고정하고, 시트 높이에 따라 가운데만 옮긴다(04-flows S6).
    static func fitRect(_ size: CGSize, sheetHeight: CGFloat) -> CGRect {
        let top: CGFloat = 110
        let h = max(80, size.height - top - (size.height * 0.25 + 24))
        let visibleMid = (top + max(top + 80, size.height - sheetHeight - 24)) / 2
        return CGRect(x: 16, y: visibleMid - h / 2, width: size.width - 32, height: h)
    }

    /// 시트 위로 보이는 영역
    private func visibleRect(_ size: CGSize) -> CGRect {
        let top: CGFloat = 110
        return CGRect(x: 16, y: top, width: size.width - 32, height: max(80, size.height - top - sheetHeight - 24))
    }

    /// 영역 가운데를 기준으로 확대하고 이동
    private func transform(_ fit: CGRect) -> CGAffineTransform {
        let s = zoom * pinch
        return CGAffineTransform(translationX: -fit.midX, y: -fit.midY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: fit.midX + pan.width + drag.width, y: fit.midY + pan.height + drag.height))
    }

    /// 재생 점이 시트 위 보이는 영역 밖으로 나가면 점을 그 영역 가운데로
    private func follow() {
        guard size != .zero, let now, let p = drawing.position(at: now) else { return }
        let fit = fitRect(size)
        let q = MapProjection(map, rect: fit).point(p.lat, p.lon).applying(transform(fit))
        let visible = visibleRect(size)
        guard !visible.insetBy(dx: 16, dy: 16).contains(q) else { return }
        pan.width += visible.midX - q.x
        pan.height += visible.midY - q.y
    }

    // MARK: 재생

    /// 하루를 약 30초에 (PlayClock: 빈 시간은 건너뜀)
    private func play() async {
        guard playing else { return }
        if progress >= 1 { progress = 0 }
        started = true
        selected = nil
        var last = Date.now
        while playing, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            let t = Date.now
            progress = min(1, progress + min(t.timeIntervalSince(last), 0.1) / 30) // 멈췄다 돌아와도 건너뛰지 않게
            last = t
            if progress >= 1 { playing = false }
        }
    }

    /// 하강 행: 지도에서 강조하고 그 하강 시작 시각으로
    private func seek(_ i: Int) {
        selected = i
        started = true
        progress = clock.progress(at: day.runs[i].start)
    }

    private var playBar: some View {
        HStack(spacing: 12) {
            Button { playing.toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.onAccent)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge) // 원 안에 머물게
                    .frame(width: 44, height: 44)
                    .background(Color.accentFill, in: Circle())
            }
            .accessibilityLabel(playing ? "일시정지" : "재생")
            Slider(value: Binding(get: { progress }, set: { progress = $0; started = true; selected = nil }), in: 0...1)
                .tint(Color.accentFill)
                .accessibilityLabel("재생 위치")
                .accessibilityValue(clock.time(at: progress).map { RecordFormat.time($0) } ?? "")
            Text(clock.time(at: progress).map { RecordFormat.time($0) } ?? "--:--")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .disabled(data == nil)
    }

    // MARK: 시트

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasRuns {
                // 25% 시트일 때만 재생 막대와 합계가 들어가게 글씨 크기를 묶는다. 50%와 목록은 끝까지 커진다.
                VStack(alignment: .leading, spacing: 12) {
                    playBar
                    DaySummary(day: day, compact: small).padding(.leading, 4)
                }
                .dynamicTypeSize(.xSmall...(small ? .accessibility1 : .accessibility5))
                .fixedSize(horizontal: false, vertical: true) // 목록에 밀려 세로로 눌리면 합계 글씨가 줄어든다
                ScrollView {
                    DayRunList(day: day, gaps: gaps, ratings: ratings, highlight: selected ?? playingRun, pinned: true, onTap: seek,
                               onDetail: data.map { _ in openDetail }, detailLocked: lock != .open)
                        .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            } else {
                ScrollView { DayNoRuns(span: span).padding(.bottom, 24) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetSize = $0 }
        .presentationDetents([.fraction(0.25), .fraction(0.5)], selection: $detent)
        .presentationBackgroundInteraction(.enabled)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .modifier(SheetBackground())
        // 시트가 떠 있는 동안에는 시트에서 띄워야 보인다
        .alert("오늘 경로가 담겨요", isPresented: $notice) {
            Button("취소", role: .cancel) {}
            Button("계속") { noticeShown = true; make() }
        } message: {
            Text("동영상 속 지도에 오늘 다닌 경로가 보여요. 받는 사람이 어느 슬로프를 탔는지 알 수 있어요.")
        }
        .sheet(isPresented: $showTicket, onDismiss: resumeAfterTicket) { SeasonTicketView() }
        .alert(SeasonRecap.pastSeasonNote, isPresented: $pastNote) { Button("확인", role: .cancel) {} }
        .alert("동영상을 만들지 못했어요", isPresented: $failed) {
            Button("닫기", role: .cancel) {}
            Button("다시 시도") { make() }
        }
        .fullScreenCover(isPresented: $showMaking) {
            ShareMakingView(thumbnail: thumb, progress: makeProgress) { making?.cancel() }
                .presentationBackground(.clear)
        }
    }

    // MARK: 공유

    private func make() {
        playing = false
        let c = ShareVideo.Content(drawing: drawing, clock: clock, title: title, count: "\(day.runs.count)회",
                                   summary: DaySummary.line(Stats.totals([day])), watermark: lock != .open)
        let size = ShareVideo.size(hd: lock == .open)
        thumb = ShareVideo.thumbnail(c)
        makeProgress = 0
        withoutAnimation { showMaking = true }
        making = Task {
            do {
                if DebugFailures.once("-SMFailVideoOnce") {
                    try await Task.sleep(for: .seconds(1)) // 만드는 중 화면이 뜬 뒤 실패
                    throw DebugFailures.Injected()
                }
                let url = try await ShareVideo.make(c, size: size) { p in Task { @MainActor in makeProgress = p } }
                withoutAnimation { showMaking = false }
                try? await Task.sleep(for: .milliseconds(350)) // 만드는 중 창이 닫힌 뒤 공유 시트
                if Task.isCancelled { try? FileManager.default.removeItem(at: url) } else { ShareSheet.present(url) }
            } catch {
                withoutAnimation { showMaking = false }
                if !(error is CancellationError) { failed = true }
            }
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, body)
    }
}

/// iOS 26부터 시트는 자동으로 유리, 그 전에는 지도가 흐리게 비치는 재질 (07-visual-design 6장)
private struct SheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content } else { content.presentationBackground(.regularMaterial) }
    }
}
