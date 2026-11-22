import SwiftUI

/// S8 시즌 보기: 주별 하강 막대(누르면 주 보기), 11~4월 작은 달력 3열(누르면 월 보기)
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
                weekBars(mine)
                Text("달력").font(.headline).foregroundStyle(Color.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(RecordCalendar.seasonMonths(season), id: \.self) { miniMonth($0, mine) }
                }
                Text("달을 누르면 월 보기로 열려요").font(.footnote).foregroundStyle(Color.secondaryText)
            }
            .padding(16)
        }
    }

    /// 주별 하강 횟수 막대. 이번 주만 진한 강조색, 누르면 그 주 보기.
    private func weekBars(_ mine: [Stats.Day]) -> some View {
        let found = RecordCalendar.weeks(season: season)
        let weeks = found.isEmpty ? [RecordCalendar.weekStart(HomeData.seasonStart(season))] : found
        let counts = weeks.map { Stats.totals(RecordCalendar.days(mine, in: RecordCalendar.weekInterval($0))).runs }
        let top = CGFloat(max(counts.max() ?? 0, 1))
        let thisWeek = RecordCalendar.weekStart(today)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("주별 하강 횟수").font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                Text("막대를 누르면 그 주로").font(.footnote).foregroundStyle(Color.secondaryText)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(zip(weeks, counts)), id: \.0) { w, n in
                            let now = w == thisWeek
                            let label = RecordCalendar.weekLabel(w)
                            Button {
                                pick(week: w)
                                mode = .week
                            } label: {
                                VStack(spacing: 4) {
                                    Text("\(n)회").font(.caption2.weight(.semibold)).monospacedDigit()
                                        .foregroundStyle(now ? Color.accentText : Color.secondaryText)
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(now ? Color.accentText : Color.accentFill.opacity(0.3))
                                        .frame(width: 28, height: max(4, 88 * CGFloat(n) / top))
                                    if now {
                                        Text("이번 주").font(.caption.weight(.semibold))
                                    } else {
                                        Text(label.month).font(.caption2)
                                        Text(label.week).font(.caption)
                                    }
                                }
                                .foregroundStyle(Color.primaryText)
                                .frame(minWidth: 48, minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(w)
                            .accessibilityLabel(now ? "이번 주, \(n)회" : "\(label.month) \(label.week), \(n)회")
                            .accessibilityHint("그 주 보기로 가요")
                        }
                    }
                }
                .onAppear { proxy.scrollTo(min(thisWeek, weeks.last!), anchor: .center) }
                .id(season) // 시즌을 바꾸면 새로 만들어 다시 스크롤
            }
        }
        .card()
    }

    private func miniMonth(_ m: Date, _ mine: [Stats.Day]) -> some View {
        let interval = RecordCalendar.monthInterval(m)
        let ridden = Set(RecordCalendar.days(mine, in: interval).filter(\.isVisit).map { RecordCalendar.dayStart($0.date) })
        let cols = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)
        let grid = RecordCalendar.monthGrid(m)
        let cells = grid + Array(repeating: nil, count: 42 - grid.count) // 늘 6줄: 카드 높이를 맞춘다
        let name = "\(RecordCalendar.cal.component(.month, from: m))월"
        return Button {
            month = m
            mode = .month
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                LazyVGrid(columns: cols, spacing: 3) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
                        Circle()
                            .fill(d.map { ridden.contains($0) ? Color.accentFill : Color.surface } ?? .clear)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: 12)
                    }
                }
            }
            .card(padding: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(interval.start > today ? 0.4 : 1)
        .accessibilityLabel("\(name), \(ridden.count)일 탔어요")
    }
}
