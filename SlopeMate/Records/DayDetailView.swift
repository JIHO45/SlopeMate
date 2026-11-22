import SwiftUI

/// S6 하루 기록. 리조트 OSM 지도가 충분하면 지도형(DayMapView, B5), 아니면 목록형(v4, 이미지로 공유 R31).
/// 홈의 최근 기록 카드(B2)와 기록 목록(S8)이 이 화면을 연다: `DayDetailView(db:day:)`.
struct DayDetailView: View {
    let db: AppDatabase
    let day: Stats.Day
    @State private var data: DayData?
    @State private var gaps: [Gap] = []
    @State private var ratings: [Int: SnowRating] = [:]
    @State private var spans: [DateInterval] = []
    @State private var failed = false
    @State private var attempt = 0

    /// 합계·목록은 경로와 같은 판정 결과로 다시 만든 하루. 읽기 전에는 넘겨받은 것
    private var shown: Stats.Day { data?.day ?? day }
    private var title: String { "\(RecordFormat.monthDay(day.date)) · \(Resort.name(day.resortId))" }

    var body: some View {
        Group {
            if failed {
                VStack(spacing: 12) {
                    Text("기록을 읽지 못했어요").font(.subheadline)
                    Button { attempt += 1 } label: { Text("다시 시도").frame(minHeight: 44) }
                        .buttonStyle(.bordered).tint(Color.accentText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.bg)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
            } else if let map = SlopeMap.cached(resortId: day.resortId), map.isDrawable {
                DayMapView(db: db, day: shown, map: map, data: data, gaps: gaps, ratings: ratings, spans: spans)
            } else {
                list
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .task(id: attempt) { await load() }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if shown.runs.isEmpty {
                    DayNoRuns(spans: spans)
                } else {
                    DaySummary(day: shown)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.surface, in: RoundedRectangle(cornerRadius: 20))
                    DayRunList(day: shown, gaps: gaps, ratings: ratings)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !shown.runs.isEmpty, data != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    // 목록형은 지도가 없어 하늘색 바탕 + 패널
                    Button { Task { await ShareImage.share(.plain, day: shown, db: db) } } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("이미지로 공유")
                }
            }
        }
    }

    private func load() async {
        failed = false
        guard let recs = try? db.recordings(of: day) else { failed = true; return }
        let (db, day, map) = (db, day, SlopeMap.cached(resortId: day.resortId))
        guard let d = await Task.detached(operation: { try? DayData.load(db, day, recs: recs, map: map) }).value else { failed = true; return }
        // 끊김·설질 평가를 못 읽으면 없는 것처럼 보이지 않게 실패로 둔다
        guard let found = try? db.gaps(recs), let all = try? recs.flatMap({ try db.snowRatings($0) }) else { failed = true; return }
        gaps = found.filter { $0.toT! >= $0.fromT.addingTimeInterval(60) } // ponytail: 1분 미만 끊김은 HH:mm로 보이지 않아 뺌
        ratings = SnowPrompt.attach(all, to: d.day.runs)
        spans = recs.compactMap { r in r.endedAt.map { DateInterval(start: r.startedAt, end: max($0, r.startedAt)) } }
        data = d
    }

    // MARK: 값

    /// 07-visual-design 2장 슬로프 난이도. OSM piste:difficulty 값
    static func difficultyColor(_ d: String) -> Color? {
        switch d {
        case "novice", "easy": Color(light: 0x2E9E4F, dark: 0x2E9E4F)
        case "intermediate": Color(light: 0x3A4FB8, dark: 0x3A4FB8)
        case "advanced", "expert", "freeride", "extreme": Color(light: 0xD93A3A, dark: 0xD93A3A)
        default: nil
        }
    }

    static func snowName(_ v: SnowRating.Value) -> String {
        switch v {
        case .ice: "아이스"
        case .ok: "적당함"
        case .slush: "슬러시"
        }
    }
}

/// 합계: 큰 횟수 + 거리·고도차·최고 속도 한 줄 + "고도 정확도 낮음". 목록형은 카드에, 지도형은 시트에 넣는다
struct DaySummary: View {
    let day: Stats.Day
    /// 지도의 25% 시트처럼 자리가 좁을 때만 합계 줄을 한 줄로 줄인다. 나머지는 줄바꿈해 큰 글씨를 지킨다.
    var compact = false

    var body: some View {
        let t = Stats.totals([day])
        VStack(alignment: .leading, spacing: 4) {
            (Text("\(t.runs)").font(.largeTitle.weight(.bold)) + Text("회").font(.title3.weight(.bold)))
                .foregroundStyle(Color.accentText).monospacedDigit()
            Text(Self.line(t)).font(.subheadline).foregroundStyle(Color.secondaryText)
                .lineLimit(compact ? 1 : nil).minimumScaleFactor(compact ? 0.6 : 1)
            if day.usedGPSAltitude {
                Label("고도 정확도 낮음", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .labelStyle(TagLabelStyle())
                    .padding(.vertical, 3).padding(.leading, 8).padding(.trailing, 10)
                    .background(Color.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.cardBorder))
                    .padding(.top, 6)
                    .accessibilityHint("동작 권한이 없거나 기압계를 쓸 수 없어 GPS 고도로 판정했어요")
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func line(_ t: Stats.Totals) -> String {
        "\(RecordFormat.km(t.distance)) · 고도차 \(Int(t.drop.rounded()).formatted())m · 최고 \(RecordFormat.kmh(t.maxSpeed))"
    }
}

/// 세션별 하강 목록과 "기록 없음" 행. 지도형 시트에서는 세션 머리줄을 위에 붙이고(pinned), 행을 누르면 onTap(하강 번호).
/// onDetail이 있으면 강조된 행 아래 "자세히"(S19, 잠금 S6 v1: 잠기면 자물쇠).
struct DayRunList: View {
    let day: Stats.Day
    let gaps: [Gap]
    let ratings: [Int: SnowRating]
    var highlight: Int? = nil
    var pinned = false
    var onTap: ((Int) -> Void)? = nil
    var onDetail: ((Int) -> Void)? = nil
    var detailLocked = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Row: Identifiable {
        case run(Int, RunDetector.Run)
        case gap(Gap)
        var id: String {
            switch self {
            case .run(let i, _): "r\(i)"
            case .gap(let g): "g\(g.fromT.timeIntervalSince1970)"
            }
        }
        var t: Date {
            switch self {
            case .run(_, let r): r.start
            case .gap(let g): g.fromT
            }
        }
    }

    /// 세션 순서대로 묶고, 기록 없음 행은 바로 앞 하강의 묶음에 시각 순으로 끼운다. 세션을 나누지 않으면 머리줄 없이 한 묶음.
    private var sections: [(kind: SessionKind?, runs: [RunDetector.Run], rows: [Row])] {
        let indexed = Array(day.runs.enumerated())
        let kinds = indexed.map { RecordFormat.session($0.element, resortId: day.resortId) }
        var out: [(kind: SessionKind?, runs: [RunDetector.Run], rows: [Row])] = []
        let order: [SessionKind?] = kinds.contains { $0 != nil } ? RecordFormat.sessionOrder.map { $0 } : [nil]
        for k in order {
            let mine = indexed.filter { kinds[$0.offset] == k || (k == .unclassified && kinds[$0.offset] == nil) }
            guard !mine.isEmpty else { continue }
            out.append((k, mine.map(\.element), mine.map { .run($0.offset, $0.element) }))
        }
        for g in gaps {
            // 앞 하강이 있는 묶음, 없으면 첫 묶음
            let i = out.lastIndex { s in s.runs.contains { $0.start <= g.fromT } } ?? 0
            guard out.indices.contains(i) else { continue }
            out[i].rows.append(.gap(g))
            out[i].rows.sort { $0.t < $1.t }
        }
        return out
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12, pinnedViews: pinned ? .sectionHeaders : []) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, s in
                Section {
                    VStack(spacing: 0) {
                        ForEach(Array(s.rows.enumerated()), id: \.element.id) { i, row in
                            if i > 0 { Divider().overlay(Color.rowSeparator) }
                            switch row {
                            case .run(let n, let r):
                                if let onTap {
                                    Button { onTap(n) } label: { runRow(n, r) }.buttonStyle(.plain)
                                } else {
                                    runRow(n, r)
                                }
                                if highlight == n, let onDetail { detailButton { onDetail(n) } }
                            case .gap(let g): gapRow(g)
                            }
                        }
                    }
                    .background(Color.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
                } header: {
                    if let k = s.kind, let first = s.runs.first, let last = s.runs.map(\.end).max() {
                        HStack {
                            Text("\(RecordFormat.sessionName(k)) \(RecordFormat.time(first.start))~\(RecordFormat.time(last))").fontWeight(.semibold)
                            Spacer()
                            Text("\(s.runs.count)회").foregroundStyle(Color.secondaryText)
                        }
                        .font(.subheadline).monospacedDigit()
                        .padding(.horizontal, 4).padding(.vertical, 4)
                        .background { if pinned { Rectangle().fill(.regularMaterial).padding(.horizontal, -16) } }
                        .accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
    }

    private func runRow(_ i: Int, _ r: RunDetector.Run) -> some View {
        let slope = SlopeNames.isShown(day.resortId) ? r.slopeId.flatMap { id in SlopeMap.cached(resortId: day.resortId)?.slopes.first { $0.id == id } } : nil
        let on = highlight == i
        // 아주 큰 글씨에서는 한 줄에 다 들어가지 않으니 세로로 쌓는다
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(RecordFormat.time(r.start)).foregroundStyle(on ? Color.accentText : Color.secondaryText).fontWeight(on ? .semibold : nil)
            let nameLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
            nameLayout {
                if let c = slope?.difficulty.flatMap({ DayDetailView.difficultyColor($0) }) {
                    Circle().fill(c).frame(width: 10, height: 10).accessibilityHidden(true)
                }
                Text(slope?.name ?? "하강 \(i + 1)").lineLimit(typeSize.isAccessibilitySize ? nil : 1).fontWeight(on ? .semibold : nil)
                if let rating = ratings[i] {
                    Text(DayDetailView.snowName(rating.value))
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.surface, in: Capsule())
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(RecordFormat.km(r.distance))
            Text(RecordFormat.kmh(r.maxSpeed)).foregroundStyle(Color.secondaryText)
                .frame(minWidth: typeSize.isAccessibilitySize ? nil : 64, alignment: .trailing)
        }
        .padding(.vertical, typeSize.isAccessibilitySize ? 8 : 0)
        .font(.subheadline).monospacedDigit()
        .foregroundStyle(Color.primaryText)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(on ? Color.surface.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// 잠금 S6 v1: 강조 행 아래 꽉 찬 44pt 캡슐
    private func detailButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if detailLocked { Image(systemName: "lock").foregroundStyle(Color.secondaryText).accessibilityHidden(true) }
                Text("자세히")
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText).accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.primaryText)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.cardBorder))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detailLocked ? "자세히, 시즌 이용권 필요" : "자세히")
        .padding(.horizontal, 16).padding(.bottom, 10)
        .background(Color.surface.opacity(0.6))
    }

    private func gapRow(_ g: Gap) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.dashed").accessibilityHidden(true)
            Text("기록 없음 \(RecordFormat.time(g.fromT))~\(RecordFormat.time(g.toT!))")
            Spacer(minLength: 0)
        }
        .font(.subheadline).monospacedDigit()
        .foregroundStyle(Color.secondaryText)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }
}

/// 하강 0회 (B0-추가 v2): 기록한 시간, 원인 3가지, 방문일 안내
struct DayNoRuns: View {
    /// 그 하루의 기록마다 시작~종료
    let spans: [DateInterval]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("하강이 기록되지 않았어요").font(.title2.weight(.bold))
                if let t = RecordFormat.recorded(spans) {
                    Text(t.line).font(.subheadline).monospacedDigit().foregroundStyle(Color.secondaryText)
                    if let range = t.range {
                        Text(range).font(.footnote).monospacedDigit().foregroundStyle(Color.secondaryText)
                    }
                }
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text("이럴 때 생겨요").font(.subheadline.weight(.semibold)).padding(.leading, 4).accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array([("building.2", "실내에 있었어요"),
                                   ("antenna.radiowaves.left.and.right.slash", "GPS 신호가 약했어요"),
                                   ("cablecar", "리프트만 탔어요")].enumerated()), id: \.offset) { i, c in
                        if i > 0 { Divider().overlay(Color.rowSeparator) }
                        HStack(spacing: 12) {
                            Image(systemName: c.0).foregroundStyle(Color.secondaryText).frame(width: 24).accessibilityHidden(true)
                            Text(c.1)
                            Spacer(minLength: 0)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                    }
                }
                .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(Color.accentText).accessibilityHidden(true)
                Text("이 기록은 방문일로 세지 않아요.")
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .foregroundStyle(Color.primaryText)
    }
}

private struct TagLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(Color(light: 0xA87400, dark: 0xF2B92E))
            configuration.title.foregroundStyle(Color.primaryText)
        }
    }
}

private extension Color {
    /// 카드 안 행 구분선 (확정 시안 #E3ECEF / #23404B)
    static let rowSeparator = Color(light: 0xE3ECEF, dark: 0x23404B)
}
