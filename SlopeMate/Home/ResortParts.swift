import SwiftUI

/// 리조트 슬로프 수를 난이도별로 센다 (R58). 지도에 있는 슬로프 기준
nonisolated struct DifficultyCounts: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let level: SlopeStyle.Level
        let count: Int
        let ratio: Double   // 난이도 정보 있는 슬로프 중 비율
    }

    private let counts: [SlopeStyle.Level: Int]

    /// OSM 슬로프만 센다. 어느 슬로프에도 이어지지 않은 그린 선 조각(`-dNN`)은 지도에만 그리고 세지 않는다(비발디 97개로 부풀던 문제)
    init(_ slopes: [SlopeMap.Slope]) {
        counts = Dictionary(grouping: slopes.filter { !$0.osmIds.isEmpty }) { SlopeStyle.level($0.difficulty) }.mapValues(\.count)
    }

    func count(_ level: SlopeStyle.Level) -> Int { counts[level] ?? 0 }
    var total: Int { counts.values.reduce(0, +) }
    var unknown: Int { count(.unknown) }

    /// 초급→최상급, 0개 구간과 정보 없음은 뺀다
    var segments: [Segment] {
        let known = total - unknown
        guard known > 0 else { return [] }
        return [SlopeStyle.Level.beginner, .intermediate, .advanced, .expert].compactMap { l in
            let n = count(l)
            return n > 0 ? Segment(level: l, count: n, ratio: Double(n) / Double(known)) : nil
        }
    }

    @MainActor static func of(_ resortId: String) -> DifficultyCounts? {
        SlopeMap.cached(resortId: resortId).map { DifficultyCounts($0.slopes) }
    }
}

extension SlopeStyle.Level {
    var color: Color { Color(light: SlopeStyle.hex(self, dark: false), dark: SlopeStyle.hex(self, dark: true)) }
}

/// 난이도 막대 (07-visual-design 6장 "R58 확정"): 높이 10, 모서리 5, 구간 사이 2. length는 전체 폭 대비 길이(0~1)
struct DifficultyBar: View {
    let counts: DifficultyCounts
    var length: Double = 1
    var body: some View {
        let segs = counts.segments
        GeometryReader { geo in
            let gaps = CGFloat(max(segs.count - 1, 0)) * 2
            let width = max(geo.size.width * length - gaps, 0)
            HStack(spacing: 2) {
                ForEach(segs, id: \.level) { s in
                    // 최상급은 어둡게에서도 테두리 없이 검정(카드 바탕이 검정이 아니라 구분됨, 2026-11-22 사용자)
                    Rectangle().fill(s.level.color)
                        .frame(width: width * s.ratio)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel(segs.map { "\(SlopeStyle.label($0.level) ?? "") \($0.count)개" }.joined(separator: ", "))
    }
}

/// 난이도 색 설명. counts가 있으면 개수도
struct DifficultyLegend: View {
    let counts: DifficultyCounts?

    var body: some View {
        HStack(spacing: 12) {
            // 개수를 보일 때는 막대처럼 0개 단계를 뺀다
            ForEach([SlopeStyle.Level.beginner, .intermediate, .advanced, .expert].filter { l in counts.map { $0.count(l) > 0 } ?? true }, id: \.self) { l in
                HStack(spacing: 4) {
                    Circle().fill(l.color).frame(width: 8, height: 8)
                    Text(counts.map { "\(SlopeStyle.label(l) ?? "") \($0.count(l))" } ?? SlopeStyle.label(l) ?? "")
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(.footnote)
        .foregroundStyle(Color.secondaryText)
    }
}

/// 오늘 운영 (R34): 확인된 시간표만 시간을 보이고, 아니면 공식 안내로. 휴장으로 표시하지 않는다. 링크는 open으로 넘긴다
struct TodayHours: View {
    let resort: Resort
    let now: Date
    let open: (URL) -> Void

    var body: some View {
        let today = Timetable.today(resortId: resort.id, now: now, timetables: ServerConfig.timetables) ?? []
        VStack(alignment: .leading, spacing: 4) {
            Text("오늘 운영").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
            if today.isEmpty {
                Text("운영 시간은 공식 안내에서 확인하세요").font(.subheadline).foregroundStyle(Color.secondaryText)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(today, id: \.interval.start) { o in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.kindLabel(o)).font(.footnote).foregroundStyle(Color.secondaryText)
                            Text("\(o.start)–\(o.end)").font(.callout.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(Color.primaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            HStack(spacing: 8) {
                link("슬로프 현황", resort.slopeStatusURL)
                if let cam = resort.webCamURL { link("웹캠", cam) }
            }
            .padding(.top, 6)
        }
        .padding(.top, 12)
    }

    static func kindLabel(_ o: Timetable.Open) -> String {
        let name = switch o.kind { case .day: "주간"; case .night: "야간"; case .lateNight: "심야" }
        return o.nextDay ? "\(name) · 다음 날" : name
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Button { open(url) } label: {
            Label(title, systemImage: "arrow.up.right.square")
                .labelStyle(IconAfter())
                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                .padding(.horizontal, 16).frame(minHeight: 44)
                .glassCapsule()
        }
        .buttonStyle(.plain)
        .accessibilityHint("앱 안 브라우저에서 열기")
    }

    /// 글자 뒤에 아이콘 ("슬로프 현황 ↗")
    private struct IconAfter: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) { configuration.title; configuration.icon.imageScale(.small) }
        }
    }
}
