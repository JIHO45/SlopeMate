import SwiftUI

/// S6 하루 기록 지도형 (v3, 하강 0회 v1; R50). 전체 화면 지도 + 닫히지 않는 아래 시트(약 25%·50%, 뒤 지도 조작 가능).
/// 지도는 내장 OSM으로 기기 안에서 그린다(MapKit·타일 없음). 시트 높이가 바뀌면 시트 위 보이는 영역에 맞춰 중심만 옮긴다.
struct DayMapView: View {
    let day: Stats.Day
    let map: SlopeMap
    /// 읽기 전 nil: 슬로프·리프트만 그린다
    let data: DayData?
    let gaps: [Gap]
    let ratings: [Int: SnowRating]
    let span: (Date, Date)?

    @Environment(\.colorScheme) private var scheme
    /// 툴바 버튼 동작은 예전 화면 값을 잡고 있을 수 있어 상태로 둔다(동영상 색)
    @State private var dark = false
    @State private var detent: PresentationDetent
    @State private var size: CGSize = .zero
    /// 시트 높이. 재기 전에는 detent 비율로 어림
    @State private var sheetSize: CGFloat?
    // 확대·이동
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
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

    init(day: Stats.Day, map: SlopeMap, data: DayData?, gaps: [Gap], ratings: [Int: SnowRating], span: (Date, Date)?) {
        (self.day, self.map, self.data, self.gaps, self.ratings, self.span) = (day, map, data, gaps, ratings, span)
        _detent = State(initialValue: day.runs.isEmpty ? .fraction(0.5) : .fraction(0.25))
    }

    /// 하강 0회면 경로·재생·공유 없이 슬로프·리프트만
    private var hasRuns: Bool { !day.runs.isEmpty }
    private var clock: PlayClock { data?.clock ?? PlayClock([]) }
    private var drawing: DayMapDrawing {
        DayMapDrawing(map: map, route: hasRuns ? data?.route ?? [] : [], showNames: SlopeNames.isShown(day.resortId), dark: dark)
    }
    /// 재생을 시작하거나 옮기기 전에는 nil(경로 전체를 진하게)
    private var now: Date? { started ? clock.time(at: progress) : nil }
    private var playingRun: Int? { now.flatMap { t in day.runs.firstIndex { $0.start <= t && t <= $0.end } } }
    private var title: String { "\(RecordFormat.monthDay(day.date)) · \(Resort.name(day.resortId))" }
    private var small: Bool { detent == .fraction(0.25) }
    private var sheetHeight: CGFloat { sheetSize ?? size.height * (detent == .fraction(0.5) ? 0.5 : 0.25) }

    var body: some View {
        Canvas { ctx, size in
            let fit = fitRect(size)
            let d = drawing, t = transform(fit), now = now, h = selected.map { day.runs[$0] }
            ctx.withCGContext { cg in d.draw(cg, size: size, MapProjection(map, rect: fit), transform: t, now: now, highlight: h) }
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .gesture(MagnifyGesture()
            .updating($pinch) { v, s, _ in s = v.magnification }
            .onEnded { zoom = min(max(zoom * $0.magnification, 1), 8) }
            .simultaneously(with: DragGesture()
                .updating($drag) { v, s, _ in s = v.translation }
                .onEnded { pan.width += $0.translation.width; pan.height += $0.translation.height }))
        .accessibilityElement()
        .accessibilityLabel("\(Resort.name(day.resortId)) 전체 슬로프 지도\(hasRuns ? " 위 오늘 경로" : "")")
        .overlay(alignment: .bottomTrailing) {
            Text("© OpenStreetMap").font(.caption).foregroundStyle(Color.secondaryText)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge) // 출처 표시가 지도를 가리지 않게
                .padding(.trailing, 16).padding(.bottom, sheetHeight + 8)
                .ignoresSafeArea()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if hasRuns, data != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { noticeShown ? make() : (notice = true) } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("동영상으로 공유")
                }
            }
        }
        .sheet(isPresented: .constant(true)) { sheet }
        .task(id: playing) { await play() }
        .onChange(of: progress) { follow() }
        .onChange(of: scheme, initial: true) { dark = scheme == .dark }
        .onDisappear { making?.cancel() }
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
            progress = min(1, progress + t.timeIntervalSince(last) / 30)
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
                    DayRunList(day: day, gaps: gaps, ratings: ratings, highlight: selected ?? playingRun, pinned: true, onTap: seek)
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
                                   summary: DaySummary.line(Stats.totals([day])))
        thumb = ShareVideo.thumbnail(c)
        makeProgress = 0
        withoutAnimation { showMaking = true }
        making = Task {
            do {
                if DebugFailures.once("-SMFailVideoOnce") {
                    try await Task.sleep(for: .seconds(1)) // 만드는 중 화면이 뜬 뒤 실패
                    throw DebugFailures.Injected()
                }
                let url = try await ShareVideo.make(c) { p in Task { @MainActor in makeProgress = p } }
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
