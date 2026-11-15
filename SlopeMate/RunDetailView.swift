import SceneKit
import SwiftUI

/// S19 하강 상세 (R52, L). 위는 이 하강만 그린 지도(고도 파일이 있으면 3D, 준비 중·없으면 2D 고정), 아래는 닫히지 않는 시트 3단계.
/// 시트: 고정 머리(재생 막대 + 지금 속도·고도) 아래 스크롤(그래프 → 숫자 4칸 → 이번 시즌 이 슬로프).
/// 내비게이션 스택 안에 놓인다. 뒤로는 시스템 뒤로 버튼. 보는 중 잠기면(환불 등) 시트를 내리고 스스로 닫는다
struct RunDetailView: View {
    let db: AppDatabase
    let day: Stats.Day
    let index: Int
    /// 그 하루 경로 전부(DayData.route). 이 하강만 잘라 그린다
    let route: [RouteSegment]
    let map: SlopeMap
    /// S6가 이미 만든 3D 지형(있으면 다시 만들지 않는다)
    let prepared3D: (space: Terrain3D, terrain: Map3DTerrain)?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(SeasonTicket.self) private var ticket
    @Environment(\.dismiss) private var dismiss
    /// 잠겨 닫는 중. 시트가 떠 있으면 뒤로 가기가 막혀 먼저 내린다
    @State private var closing = false
    @AppStorage("mapShowSlopes") private var showSlopes = true
    @AppStorage("mapShowLifts") private var showLifts = true
    @ScaledMetric(relativeTo: .largeTitle) private var bigSize = 44
    @ScaledMetric(relativeTo: .body) private var bigUnit = 17
    @ScaledMetric(relativeTo: .title2) private var cellSize = 22
    @ScaledMetric(relativeTo: .subheadline) private var cellUnit = 15

    @State private var detent: PresentationDetent
    @State private var size: CGSize = .zero
    @State private var sheetSize: CGFloat?
    @State private var loaded: RunDetail.Loaded?
    @State private var failed = false
    @State private var attempt = 0
    @State private var scene3D: Map3DScene?
    @State private var ready3D = false
    @State private var progress = 0.0
    @State private var playing = false
    @State private var started = false
    @State private var scrolled = false
    /// 재생·경로 구간. 읽은 뒤에는 앞뒤 정지를 뺀 그래프 구간(series.start~end)으로 한 번 바꾼다
    @State private var runRoute: [RouteSegment]
    @State private var clock: PlayClock

    static let small = PresentationDetent.height(196), medium = PresentationDetent.fraction(0.6), large = PresentationDetent.fraction(0.9)

    init(db: AppDatabase, day: Stats.Day, index: Int, route: [RouteSegment], map: SlopeMap,
         prepared3D: (space: Terrain3D, terrain: Map3DTerrain)? = nil) {
        (self.db, self.day, self.index, self.route, self.map, self.prepared3D) = (db, day, index, route, map, prepared3D)
        let r = RunDetail.route(route, run: day.runs[index])
        (_runRoute, _clock) = (State(initialValue: r), State(initialValue: PlayClock(r)))
        // 미리보기·스크린숏: -SMRunDetailDetent small|medium|large
        let a = ProcessInfo.processInfo.arguments
        let start = a.firstIndex(of: "-SMRunDetailDetent").flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil }
        _detent = State(initialValue: start == "large" ? Self.large : start == "medium" ? Self.medium : Self.small)
    }

    private var run: RunDetector.Run { day.runs[index] }
    private var dark: Bool { scheme == .dark }
    private var layers: MapLayers { MapLayers(slopes: showSlopes, lifts: showLifts) }
    private var drawing: DayMapDrawing {
        DayMapDrawing(map: map, route: runRoute, dark: dark, terrain: Terrain.layer(map, dark: dark), layers: layers)
    }
    /// 재생을 시작하거나 옮기기 전에는 nil(경로·그래프 전체를 진하게)
    private var now: Date? { started ? clock.time(at: progress) : nil }
    /// 재생 막대·지금 숫자의 시각(재생 전에는 시작)
    private var shownTime: Date? { clock.time(at: progress) }
    private var ax: Bool { typeSize.isAccessibilitySize }
    /// 시트 높이. 지도는 중간 단계까지만 따라 옮기고, 크게에서는 그대로 둔다
    private var sheetHeight: CGFloat { sheetSize ?? 196 }
    private var mapInset: CGFloat { min(sheetHeight, size.height * 0.6) }

    private var slope: SlopeMap.Slope? {
        SlopeNames.isShown(day.resortId) ? run.slopeId.flatMap { id in map.slopes.first { $0.id == id } } : nil
    }
    private var name: String { slope?.name ?? "하강 \(index + 1)" }
    private var title: String {
        SlopeStyle.label(SlopeStyle.level(slope?.difficulty)).map { "\(name) · \($0)" } ?? name
    }

    var body: some View {
        ZStack {
            if !(scene3D != nil && ready3D) { canvas.transition(.opacity) }
            if let scene3D {
                Map3DView(scene: scene3D, now: now, highlight: nil, dark: dark, bottomInset: mapInset + 24, reduceMotion: reduceMotion,
                          layers: layers, flyIn: !reduceMotion,
                          onReady: {
                              withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { ready3D = true }
                              if !started { playing = true } // 3D가 보인 뒤 재생
                              Task { await scene3D.loadDetail() } // 화면 크기가 정해진 뒤 보이는 땅만 고해상(나무 모양)
                          })
                    .ignoresSafeArea()
                    .opacity(ready3D ? 1 : 0)
                    .accessibilityElement()
                    .accessibilityLabel(mapLabel(threeD: true))
                    .accessibilityHidden(!ready3D)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .overlay(alignment: .bottomTrailing) {
            if sheetHeight < size.height * 0.75 { // 크게에서는 가려짐
                Text(drawing.terrain == nil ? "© OpenStreetMap" : "© OpenStreetMap · Copernicus DEM").font(.caption).foregroundStyle(Color.secondaryText)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .padding(.trailing, 16).padding(.bottom, sheetHeight + 8)
                    .ignoresSafeArea()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    if let c = slope?.difficulty.flatMap({ DayDetailView.difficultyColor($0) }) {
                        Circle().fill(c).frame(width: 10, height: 10).accessibilityHidden(true)
                    }
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.card, in: Capsule()) // 어두운 3D 위에서도 읽히게
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
        .sheet(isPresented: .constant(!closing)) { sheet }
        .onChange(of: DayMapView.lock(day: day.date, owned: ticket.seasons)) { _, lock in
            guard lock != .open, !closing else { return }
            closing = true
            dismiss()
        }
        .task(id: attempt) { await load() }
        .task(id: loaded == nil) { await prepare3D() }
        .task(id: playing) { await play() }
    }

    // MARK: 지도

    private func mapLabel(threeD: Bool) -> String {
        "\(threeD ? "3D 지형" : "지도")에서 \(name)\(Self.objectParticle(name)) 내려오는 모습"
            + ((loaded?.series.gaps.isEmpty ?? true) ? "" : ", 기록 없음 구간은 경로가 끊겨 있음")
    }

    /// 을/를: 받침 있는 한글·받침으로 읽는 숫자(0·1·3·6·7·8)는 "을"
    static func objectParticle(_ word: String) -> String {
        guard let c = word.unicodeScalars.last else { return "를" }
        if (0xAC00...0xD7A3).contains(c.value) { return (c.value - 0xAC00) % 28 == 0 ? "를" : "을" }
        return "013678".unicodeScalars.contains(c) ? "을" : "를"
    }

    /// 2D: 하강 전체가 시트 위 영역(중간 단계까지)에 들어오게 확대해 고정. 손짓 없음
    private var canvas: some View {
        let d = drawing, now = now, map = map, inset = mapInset
        return Canvas { ctx, size in
            let fit = DayMapView.fitRect(size, sheetHeight: size.height * 0.25)
            let proj = MapProjection(map, rect: fit)
            let pts = d.route.flatMap(\.points).map { proj.point($0.lat, $0.lon) }
            let area = CGRect(x: 32, y: 126, width: size.width - 64, height: max(80, size.height - 126 - inset - 40))
            let t = Self.frame(pts, in: area, fit: fit)
            ctx.withCGContext { cg in d.draw(cg, size: size, proj, transform: t, now: now) }
        }
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel(mapLabel(threeD: false))
    }

    /// 2D 고정 시점: 점들의 상자가 area 가운데에 들어오는 확대(최대 8배)·이동. 점이 없으면 리조트 전체(fit)를 area에
    static func frame(_ points: [CGPoint], in area: CGRect, fit: CGRect) -> CGAffineTransform {
        var box = fit
        if let p = points.first {
            box = points.reduce(CGRect(origin: p, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        let s = min(area.width / max(box.width, 1), area.height / max(box.height, 1), 8)
        return CGAffineTransform(translationX: -box.midX, y: -box.midY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: area.midX, y: area.midY))
    }

    /// 지형 메시는 메인 스레드 밖에서(DayMapView.toggle3D와 같은 순서). 경로 구간이 정해진 뒤(읽은 뒤) 만들고, 준비되면 onReady에서 2D와 겹쳐 바꾼다
    private func prepare3D() async {
        let route = runRoute
        guard loaded != nil, scene3D == nil, !route.isEmpty, let terrain = drawing.terrain?.terrain else { return }
        let map = map
        let pair: (Terrain3D, Map3DTerrain)
        if let p = prepared3D {
            pair = (p.space, p.terrain.copy()) // S6 장면과 재질을 따로 갖게 지오메트리만 복사
        } else {
            pair = await Task.detached(priority: .userInitiated) {
                let space = Terrain3D(terrain: terrain, map: map)
                return (space, Map3DTerrain(space: space, map: map))
            }.value
        }
        let (space, prepared) = pair
        guard !Task.isCancelled else { return }
        scene3D = Map3DScene(space: space, terrain: prepared, map: map, route: route, dark: dark,
                             viewport: size == .zero ? CGSize(width: 393, height: 852) : size,
                             view3D: Resort.all.first { $0.id == day.resortId }?.view3D,
                             fitPoints: route.flatMap(\.points).map { (lat: $0.lat, lon: $0.lon) })
    }

    // MARK: 읽기·재생

    private func load() async {
        failed = false
        let (db, day, index) = (db, day, index)
        do {
            let l = try await Task.detached(priority: .userInitiated) { try RunDetail.load(db, day: day, index: index) }.value
            var r = run
            (r.start, r.end) = (l.series.start, l.series.end)
            runRoute = RunDetail.route(route, run: r)
            clock = PlayClock(runRoute)
            loaded = l
            // 시안은 재생 중 모습: 들어오면 바로 재생. 3D가 뜨면 onReady에서(나는 동안 재생이 앞서 가지 않게)
            if !started && (drawing.terrain == nil || runRoute.isEmpty) { playing = true; return }
            // 3D가 2초 안에 안 뜨면 2D로 재생을 시작한다(3D가 나중에 뜨면 그 위치에서 이어 감)
            try? await Task.sleep(for: .seconds(2))
            if !started && !Task.isCancelled { playing = true }
        } catch {
            failed = true
        }
    }

    /// 하강 하나를 playSeconds에 (PlayClock: 끊긴 구간은 잠깐 머문 뒤 건너뜀)
    private func play() async {
        guard playing else { return }
        if progress >= 1 { progress = 0 }
        started = true
        var last = Date.now
        while playing, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            let t = Date.now
            progress = min(1, progress + min(t.timeIntervalSince(last), 0.1) / RunDetail.playSeconds) // 멈췄다 돌아와도 건너뛰지 않게
            last = t
            if progress >= 1 { playing = false }
        }
    }

    // MARK: 시트

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 작게(196pt)에 들어가게 머리 글씨는 accessibility1까지. 접근성 크기에서는 지금 숫자를 스크롤로 내린다
            VStack(alignment: .leading, spacing: 14) {
                playBar
                if !ax { nowNumbers }
            }
            .dynamicTypeSize(.xSmall...(detent == Self.small ? .accessibility1 : .accessibility5))
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if ax { nowNumbers }
                    if let loaded {
                        charts(loaded.series)
                        numbers(loaded.series)
                        if let h = loaded.history { RunHistoryChart(history: h).box() }
                    } else if failed {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("기록을 읽지 못했어요").font(.subheadline)
                            Button { attempt += 1 } label: { Text("다시 시도").frame(minHeight: 44) }
                                .buttonStyle(.bordered).tint(Color.accentText)
                        }
                        .box()
                    }
                }
                .padding(.bottom, 24)
                .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY < -1 } action: { scrolled = $0 }
            }
            .scrollIndicators(.hidden)
            // 작게에서는 머리만(시안). 그 아래 카드가 비져 보이지 않게
            .opacity(detent == Self.small && !ax ? 0 : 1)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.chartLine).frame(height: 1).padding(.horizontal, -16).opacity(scrolled ? 1 : 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetSize = $0 }
        .presentationDetents([Self.small, Self.medium, Self.large], selection: $detent)
        .presentationBackgroundInteraction(.enabled)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .modifier(RunSheetBackground())
    }

    /// S6 playBar와 같은 모양
    private var playBar: some View {
        HStack(spacing: 12) {
            Button { playing.toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.onAccent)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .frame(width: 44, height: 44)
                    .background(Color.accentFill, in: Circle())
            }
            .accessibilityLabel(playing ? "일시정지" : "재생")
            Slider(value: Binding(get: { progress }, set: { progress = $0; started = true }), in: 0...1)
                .tint(Color.accentFill)
                .accessibilityLabel("재생 위치")
                .accessibilityValue(shownTime.map { RecordFormat.time($0) } ?? "")
            Text(shownTime.map { RecordFormat.time($0) } ?? "--:--")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .disabled(loaded == nil || runRoute.isEmpty)
    }

    private var nowNumbers: some View {
        let s = loaded.flatMap { l in shownTime.flatMap { l.series.speed(at: $0) } }
        let a = loaded.flatMap { l in shownTime.flatMap { l.series.altitude(at: $0) } }
        let layout = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return layout {
            nowCell("지금 속도", s.map { "\(Int(($0 * 3.6).rounded()))" }, "km/h", accent: true)
            nowCell("지금 고도", a.map { Int($0.rounded()).formatted() }, "m", accent: false)
        }
        .padding(.horizontal, 4)
    }

    private func nowCell(_ label: String, _ value: String?, _ unit: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.footnote).foregroundStyle(Color.secondaryText)
            (Text(value ?? "--").font(.system(size: bigSize, weight: .bold)) + Text(unit).font(.system(size: bigUnit, weight: .semibold)))
                .foregroundStyle(accent ? Color.accentText : Color.primaryText)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value.map { $0 + unit } ?? "없음")")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func charts(_ series: RunDetail.Series) -> some View {
        let first = series.pieces.first?.altitude.first?.v, last = series.pieces.last?.altitude.last?.v
        let altNote = first.flatMap { f in last.map { "\(Int(f.rounded()).formatted())m → \(Int($0.rounded()).formatted())m" } } ?? ""
        let speedNote = RunDetail.gapText(series.gaps)
            ?? "최고 \(Int((run.maxSpeed * 3.6).rounded())) · 평균 \(Int((run.avgSpeed * 3.6).rounded()))"
        return VStack(alignment: .leading, spacing: 8) {
            RunChart(kind: .speed, series: series, now: now, note: speedNote)
            RunChart(kind: .altitude, series: series, now: now, note: altNote)
        }
        .box()
    }

    /// 숫자 4칸: 하강 목록과 같은 값(RunDetector.Run). 접근성 크기에서는 1열
    private func numbers(_ series: RunDetail.Series) -> some View {
        let stopped = Int(series.stopped.rounded())
        let cells: [(String, String, String, String?)] = [
            ("거리", String(format: "%.1f", run.distance / 1000), "km", nil),
            ("고도차", Int(run.drop.rounded()).formatted(), "m", nil),
            ("최고 속도", "\(Int((run.maxSpeed * 3.6).rounded()))", "km/h", series.maxAt.map { RecordFormat.time($0) }),
            ("평균 속도", "\(Int((run.avgSpeed * 3.6).rounded()))", "km/h", stopped > 0 ? "멈춘 \(stopped / 60):\(String(format: "%02d", stopped % 60)) 제외" : nil),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .topLeading), count: ax ? 1 : 2), spacing: 0) {
            ForEach(cells, id: \.0) { c in
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.0).font(.footnote).foregroundStyle(Color.secondaryText)
                    (Text(c.1).font(.system(size: cellSize, weight: .bold)) + Text(c.2).font(.system(size: cellUnit, weight: .semibold)))
                        .monospacedDigit()
                    // 셋째 줄은 아래 줄(최고·평균 속도)만. 윗줄은 자리를 두지 않는다
                    if c.3 != nil || cells[2...].contains(where: { $0.0 == c.0 }) {
                        Text(c.3 ?? " ").font(.footnote).foregroundStyle(Color.secondaryText).monospacedDigit()
                            .accessibilityHidden(c.3 == nil)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(c.0) \(c.1)\(c.2)\(c.3.map { ", \($0)" } ?? "")")
            }
        }
        .foregroundStyle(Color.primaryText)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
    }
}

private extension View {
    /// S19 카드: 흰(어둡게 짙은) 면, 테두리, 둥근 모서리 20, 안쪽 16
    func box() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.primaryText)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
    }
}

private extension Map3DTerrain {
    /// 메시 데이터는 나누고 재질은 따로 쓰는 복사(SCNGeometry.copy)
    func copy() -> Map3DTerrain { Map3DTerrain(geometry: geometry.copy() as! SCNGeometry, texture: texture) }
    init(geometry: SCNGeometry, texture: CGImage?) { self.geometry = geometry; self.texture = texture }
}

/// iOS 26부터 시트는 자동으로 유리, 그 전에는 지도가 흐리게 비치는 재질 (S6와 같음)
private struct RunSheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content } else { content.presentationBackground(.regularMaterial) }
    }
}

#Preview {
    NavigationStack {
        if let map = SlopeMap.load(resortId: "high1"), let db = try? AppDatabase(path: ":memory:") {
            RunDetailView(db: db, day: Stats.Day(date: .now, resortId: "high1",
                                                 runs: [RunDetector.Run(start: .now, end: .now.addingTimeInterval(360), distance: 1800,
                                                                        drop: 412, maxSpeed: 17, avgSpeed: 12, movingTime: 300)],
                                                 usedGPSAltitude: false),
                          index: 0, route: [], map: map)
        }
    }
}

