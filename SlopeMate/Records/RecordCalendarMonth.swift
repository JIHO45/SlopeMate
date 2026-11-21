import SwiftUI

/// S8 월 보기: 한 달 달력 + "n월 기록" 목록(밀어서 삭제). swipeActions 때문에 List.
extension RecordCalendarView {
    func monthView(_ all: [Stats.Day]) -> some View {
        let months = RecordCalendar.seasonMonths(season)
        let i = months.firstIndex(of: month) ?? 0
        let shown = RecordCalendar.days(all, in: RecordCalendar.monthInterval(month)).sorted { $0.date > $1.date }
        let t = Stats.totals(shown)
        let photos = shown.filter { thumbs[$0.id] != nil }.count
        let m = RecordCalendar.cal.component(.month, from: month)
        return List {
            VStack(spacing: 12) {
                navHeader(Self.yearMonth.string(from: month), "\(t.visitDays)일 · \(t.runs)회" + (photos > 0 ? " · 사진 \(photos)장" : ""), unit: "달",
                          prev: i > 0 ? { month = months[i - 1] } : nil,
                          next: i < months.count - 1 ? { month = months[i + 1] } : nil)
                monthGrid(all)
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            if !shown.isEmpty {
                Section {
                    ForEach(shown) { day in
                        NavigationLink { DayDetailView(db: db, day: day) } label: { monthRow(day) }
                            .listRowBackground(Color.card)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
                            .swipeActions { Button("삭제", role: .destructive) { deleting = day } }
                    }
                } header: {
                    Text("\(m)월 기록")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText).textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func monthGrid(_ all: [Stats.Day]) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(Self.weekdays, id: \.self) {
                    Text($0).font(.caption).foregroundStyle(Color.secondaryText).frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(Array(RecordCalendar.monthGrid(month).enumerated()), id: \.offset) { _, d in
                    if let d { monthCell(d, all) } else { Color.clear.frame(height: 44) }
                }
            }
        }
    }

    private func monthCell(_ d: Date, _ all: [Stats.Day]) -> some View {
        let recs = records(on: d, all)
        let ridden = recs.contains(where: \.isVisit)
        let img = recs.lazy.compactMap { thumbs[$0.id] }.first
        let n = RecordCalendar.cal.component(.day, from: d)
        return Button { open(day: d) } label: {
            ZStack {
                if let img {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if ridden {
                    Circle().fill(Color.accentFill)
                } else if !recs.isEmpty {
                    Circle().strokeBorder(Color.accentText, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                }
                Text("\(n)")
                    .font(.subheadline.weight(recs.isEmpty ? .regular : .semibold)).monospacedDigit()
                    .foregroundStyle(img != nil ? .white : ridden ? Color.onAccent : Color.primaryText)
                    .shadow(color: img != nil ? .black.opacity(0.6) : .clear, radius: 2)
            }
            .frame(width: 44, height: 44)
            .overlay {
                if d == today {
                    RoundedRectangle(cornerRadius: img != nil ? 12 : 22).strokeBorder(Color.accentText, lineWidth: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if recs.count > 1 {
                    Text("\(recs.count)").font(.caption2.weight(.bold)).foregroundStyle(Color.onAccent)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Color.accentText, in: Circle())
                        .offset(x: 4, y: -4)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(d > today)
        .opacity(d > today ? 0.4 : 1)
        .accessibilityLabel(Self.dayTitle.string(from: d) + (recs.isEmpty ? "" : ", "
            + recs.map { "\(Resort.name($0.resortId)) \($0.runs.count)회" }.joined(separator: ", ")
            + (img != nil ? ", 사진 있음" : "")))
    }

    private func monthRow(_ day: Stats.Day) -> some View {
        let s = RecordFormat.sessionNames(day)
        return HStack(spacing: 12) {
            if let img = thumbs[day.id] {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
            } else {
                IconCircle(systemName: "figure.skiing.downhill", size: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.dayShort.string(from: day.date)) · \(Resort.name(day.resortId))")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                Text((["\(day.runs.count)회", RecordFormat.km(day.runs.reduce(0) { $0 + $1.distance })] + (s.isEmpty ? [] : [s]))
                    .joined(separator: " · "))
                    .font(.footnote).foregroundStyle(Color.secondaryText).monospacedDigit()
            }
        }
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
    }
}
