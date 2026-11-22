import SwiftUI

/// 리조트 비교 (R58 v4). 홈 "비교"에서 연다. 맨 위 난이도 색 설명 한 번, "★ 즐겨찾기"(저장 순서)·"다른 리조트"(슬로프 많은 순).
/// 줄: 이름·전체 개수, 그 아래 막대(길이는 가장 많은 리조트 대비). 줄을 누르면 리조트 화면. 날씨는 조회하지 않는다
struct ResortCompareView: View {
    let db: AppDatabase
    let cache: WeatherCache
    @Binding var favorites: [String]

    var body: some View {
        // ponytail: 지도 파일이 없는 리조트는 뺀다(번들 12곳은 모두 있음)
        let all = Resort.all.compactMap { r in DifficultyCounts.of(r.id).map { (id: r.id, counts: $0) } }
        let max = Double(all.map(\.counts.total).max() ?? 1)
        let mine = favorites.compactMap { id in all.first { $0.id == id } }
        let others = all.filter { !favorites.contains($0.id) }
            .sorted { ($0.counts.total, Resort.name($1.id)) > ($1.counts.total, Resort.name($0.id)) }
        List {
            Section { DifficultyLegend(counts: nil) }
            if !mine.isEmpty {
                Section("★ 즐겨찾기") { ForEach(mine, id: \.id) { row($0.id, $0.counts, max) } }
            }
            Section {
                ForEach(others, id: \.id) { row($0.id, $0.counts, max) }
            } header: {
                Text("다른 리조트")
            } footer: {
                Text("지도에 있는 슬로프 수예요. 공식 개수와 다를 수 있어요. 막대 길이는 슬로프 수, 색은 난이도 비율이에요.")
            }
        }
        .navigationTitle("리조트 비교")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ id: String, _ counts: DifficultyCounts, _ max: Double) -> some View {
        NavigationLink {
            ResortView(db: db, resortId: id, cache: cache, favorites: $favorites)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(Resort.name(id)).font(.body.weight(.semibold))
                    Spacer()
                    Text("\(counts.total)개").monospacedDigit().foregroundStyle(Color.secondaryText)
                }
                .accessibilityElement(children: .combine)
                DifficultyBar(counts: counts, length: Double(counts.total) / max)
            }
            .padding(.vertical, 4)
        }
    }
}

#Preview {
    NavigationStack {
        if let db = try? AppDatabase(path: ":memory:") {
            ResortCompareView(db: db, cache: WeatherCache(), favorites: .constant(["high1", "yongpyong"]))
        }
    }
}
