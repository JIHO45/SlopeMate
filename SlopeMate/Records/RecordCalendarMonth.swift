import SwiftUI

/// S8 월 보기: 한 달 달력, "n월 합계" 네 칸과 지난달 비교, "n월 사진" 모아보기. 날짜나 사진을 누르면 그 주.
extension RecordCalendarView {
    func monthView(_ all: [Stats.Day]) -> some View {
        let months = RecordCalendar.seasonMonths(season)
        let i = months.firstIndex(of: month) ?? 0
        let shown = RecordCalendar.days(all, in: RecordCalendar.monthInterval(month)).sorted { $0.date < $1.date }
        let (t, delta) = RecordCalendar.monthTotals(all, month: month, season: season)
        let m = RecordCalendar.cal.component(.month, from: month)
        let photos = shown.filter { thumbs[$0.id] != nil }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                navHeader(Self.yearMonth.string(from: month), "\(t.visitDays)일 · \(t.runs)회", unit: "달",
                          prev: i > 0 ? { month = months[i - 1] } : nil,
                          next: i < months.count - 1 ? { month = months[i + 1] } : nil)
                monthGrid(all)
                sectionTitle("\(m)월 합계")
                VStack(alignment: .leading, spacing: 12) {
                    totalsRow(t)
                    if let delta {
                        Group {
                            if delta == 0 {
                                Text("지난달과 방문일이 같아요")
                            } else {
                                Text("지난달보다 방문 \(Text("\(abs(delta))일").bold()) \(delta > 0 ? "많아요" : "적어요")")
                            }
                        }
                        .font(.subheadline).foregroundStyle(Color.secondaryText)
                    }
                }
                if !photos.isEmpty {
                    sectionTitle("\(m)월 사진 \(photos.count)장")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(photos) { photoTile($0) }
                    }
                }
                Text("날짜나 사진을 누르면 그 주로 가요")
                    .font(.footnote).foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity)
            }
            .padding(16)
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.headline).foregroundStyle(Color.primaryText).accessibilityAddTraits(.isHeader)
    }

    private func totalsRow(_ t: Stats.Totals) -> some View {
        let km = RecordFormat.km(t.distance)
        let cells: [(String, String, String)] = [
            ("방문일", "\(t.visitDays)", "일"),
            ("하강", "\(t.runs)", "회"),
            ("거리", String(km.dropLast(2)), "km"),
            ("고도차", Int(t.drop.rounded()).formatted(), "m"),
        ]
        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { k, c in
                if k > 0 { Divider().frame(maxHeight: 40) }
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(c.1).font(.system(size: 20, weight: .bold)).monospacedDigit()
                        Text(c.2).font(.system(size: 14))
                    }
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    Text(c.0).font(.footnote).foregroundStyle(Color.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(c.0) \(c.1)\(c.2)")
            }
        }
        .card(padding: 14)
    }

    private func photoTile(_ day: Stats.Day) -> some View {
        Button { open(day: RecordCalendar.dayStart(day.date)) } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { if let img = thumbs[day.id] { Image(uiImage: img).resizable().scaledToFill() } }
                .overlay(alignment: .bottomLeading) {
                    ZStack(alignment: .bottomLeading) {
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                        Text(RecordFormat.monthDay(day.date))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(RecordFormat.monthDay(day.date)) \(Resort.name(day.resortId)) 사진")
        .accessibilityHint("그 주로 가요")
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
}
