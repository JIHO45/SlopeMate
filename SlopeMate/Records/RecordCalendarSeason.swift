import SwiftUI

/// S8 시즌 보기: 11~4월 작은 달력 6개, 달을 누르면 월 보기
extension RecordCalendarView {
    func seasonView(_ all: [Stats.Day]) -> some View {
        let mine = Stats.days(all, inSeason: season)
        let t = Stats.totals(mine)
        let seasons = Set(all.compactMap { Stats.season(of: $0.date) } + [HomeData.currentSeason(), season]).sorted()
        let i = seasons.firstIndex(of: season) ?? 0
        return ScrollView {
            VStack(spacing: 16) {
                navHeader("\(season) 시즌", "\(t.visitDays)일 · \(t.runs)회 · \(RecordFormat.km(t.distance))", unit: "시즌",
                          prev: i > 0 ? { show(season: seasons[i - 1]) } : nil,
                          next: i < seasons.count - 1 ? { show(season: seasons[i + 1]) } : nil)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(RecordCalendar.seasonMonths(season), id: \.self) { miniMonth($0, mine) }
                }
                Text("달을 누르면 월 보기로 열려요").font(.footnote).foregroundStyle(Color.secondaryText)
            }
            .padding(16)
        }
    }

    private func miniMonth(_ m: Date, _ mine: [Stats.Day]) -> some View {
        let interval = RecordCalendar.monthInterval(m)
        let ridden = Set(RecordCalendar.days(mine, in: interval).filter(\.isVisit).map { RecordCalendar.dayStart($0.date) })
        let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        let grid = RecordCalendar.monthGrid(m)
        let cells = grid + Array(repeating: nil, count: 42 - grid.count) // 늘 6줄: 카드 높이를 맞춘다
        let name = "\(RecordCalendar.cal.component(.month, from: m))월"
        return Button {
            month = m
            mode = .month
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                LazyVGrid(columns: cols, spacing: 3) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
                        Circle()
                            .fill(d.map { ridden.contains($0) ? Color.accentFill : Color.surface } ?? .clear)
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .card(padding: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(interval.start > today ? 0.4 : 1)
        .accessibilityLabel("\(name), \(ridden.count)일 탔어요")
    }
}
