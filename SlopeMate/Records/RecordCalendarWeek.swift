import SwiftUI

/// S8 주 보기: 주별 하강 막대, 요일 줄, 고른 날 카드, 사진 칸
extension RecordCalendarView {
    private static let dayCard = Color(red: 0x0F / 255, green: 0x3D / 255, blue: 0x45 / 255)

    func weekView(_ every: [Stats.Day]) -> some View {
        let all = Stats.days(every, inSeason: season) // 시즌 밖(10월·5월) 날은 세지 않는다
        let found = RecordCalendar.weeks(season: season)
        let weeks = found.isEmpty ? [RecordCalendar.weekStart(HomeData.seasonStart(season))] : found
        let t = Stats.totals(RecordCalendar.days(all, in: RecordCalendar.weekInterval(week)))
        let i = weeks.firstIndex(of: week) ?? weeks.count - 1
        let recs = records(on: selected, all)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                navHeader(RecordCalendar.weekRange(week), "\(t.visitDays)일 · \(t.runs)회", unit: "주",
                          prev: i > 0 ? { pick(week: weeks[i - 1]) } : nil,
                          next: i < weeks.count - 1 ? { pick(week: weeks[i + 1]) } : nil)
                bars(weeks, all)
                dayStrip(all)
                Text(Self.dayTitle.string(from: selected))
                    .font(.title3.weight(.bold)).foregroundStyle(Color.primaryText)
                    .accessibilityAddTraits(.isHeader)
                if let first = recs.first {
                    bigCard(first)
                    ForEach(recs.dropFirst()) { smallCard($0) }
                    Text("사진").font(.headline).foregroundStyle(Color.primaryText).accessibilityAddTraits(.isHeader)
                    ForEach(recs) { photoSlot($0, titled: recs.count > 1) }
                } else {
                    Text("이날은 기록이 없어요")
                        .font(.body.weight(.semibold)).foregroundStyle(Color.secondaryText)
                        .dashedBox()
                }
            }
            .padding(16)
        }
    }

    private func bars(_ weeks: [Date], _ all: [Stats.Day]) -> some View {
        let counts = weeks.map { Stats.totals(RecordCalendar.days(all, in: RecordCalendar.weekInterval($0))).runs }
        let top = CGFloat(max(counts.max() ?? 0, 1))
        let thisWeek = RecordCalendar.weekStart(today)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("주별 하강 횟수").font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                Text("막대를 눌러 주 고르기").font(.footnote).foregroundStyle(Color.secondaryText)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(zip(weeks, counts)), id: \.0) { w, n in
                            let on = w == week
                            let label = RecordCalendar.weekLabel(w)
                            Button { pick(week: w) } label: {
                                VStack(spacing: 4) {
                                    Text("\(n)회").font(.caption2.weight(.semibold)).monospacedDigit()
                                        .foregroundStyle(on ? Color.accentText : Color.secondaryText)
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(on ? Color.accentText : Color.accentFill.opacity(0.3))
                                        .frame(width: 28, height: max(4, 88 * CGFloat(n) / top))
                                    if w == thisWeek {
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
                            .anchorPreference(key: SelectedBar.self, value: .bounds) { on ? $0 : nil }
                            .id(w)
                            .accessibilityLabel(w == thisWeek ? "이번 주, \(n)회" : "\(label.month) \(label.week), \(n)회")
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
                .onAppear { proxy.scrollTo(week, anchor: .center) }
                .onChange(of: week) { _, w in withAnimation { proxy.scrollTo(w, anchor: .center) } }
            }
        }
        .card()
        // 카드 아래 꺾쇠: 고른 막대 밑에서 요일 줄을 가리킨다
        .overlayPreferenceValue(SelectedBar.self) { a in
            GeometryReader { g in
                if let a, (16...g.size.width - 16).contains(g[a].midX) {
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(Color.accentText)
                        .position(x: g[a].midX, y: g.size.height + 8)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func dayStrip(_ all: [Stats.Day]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(RecordCalendar.weekDays(week).enumerated()), id: \.element) { i, d in
                let recs = records(on: d, all)
                let on = d == selected
                let future = d > today
                Button { selected = d } label: {
                    VStack(spacing: 6) {
                        Text(Self.weekdays[i]).font(.footnote).tracking(3).foregroundStyle(Color.secondaryText)
                        Text("\(RecordCalendar.cal.component(.day, from: d))")
                            .font(.body.weight(on ? .bold : .regular)).monospacedDigit()
                            .foregroundStyle(Color.primaryText)
                        HStack(spacing: 3) {
                            ForEach(recs) { r in
                                if r.isVisit {
                                    Circle().fill(Color.accentFill).frame(width: 6, height: 6)
                                } else {
                                    Circle().strokeBorder(Color.accentText, lineWidth: 1).frame(width: 6, height: 6)
                                }
                            }
                        }
                        .frame(height: 6)
                    }
                    .frame(width: 48, height: 72)
                    .background(on ? Color.card : .clear, in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        if d == today { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentText, lineWidth: 1.5) }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(future)
                .opacity(future ? 0.4 : 1)
                .accessibilityLabel(Self.dayTitle.string(from: d) + (recs.isEmpty ? ", 기록 없음"
                    : ", " + recs.map { "\(Resort.name($0.resortId)) \($0.runs.count)회" }.joined(separator: ", ")))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
        .background(Color.accentFill.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
    }

    private func subtitle(_ r: Stats.Day) -> String {
        let s = RecordFormat.sessionNames(r)
        return ([Resort.name(r.resortId)] + (s.isEmpty ? [] : [s])).joined(separator: " · ")
    }

    private func bigCard(_ r: Stats.Day) -> some View {
        VStack(spacing: 8) {
            Text(subtitle(r)).font(.subheadline.weight(.semibold)).opacity(0.85)
            BigCount(runs: r.runs.count)
            Text(RecordFormat.km(r.runs.reduce(0) { $0 + $1.distance })).font(.subheadline).opacity(0.85)
            NavigationLink { DayDetailView(db: db, day: r) } label: {
                Text("기록 보기").font(.subheadline.weight(.bold)).foregroundStyle(Self.dayCard)
                    .padding(.horizontal, 24).frame(minHeight: 44)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 240)
        .background {
            ZStack(alignment: .bottom) {
                Self.dayCard
                Image(systemName: "mountain.2.fill").font(.system(size: 180))
                    .foregroundStyle(.white.opacity(0.07)).offset(y: 40)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .accessibilityHidden(true)
        }
    }

    private func smallCard(_ r: Stats.Day) -> some View {
        NavigationLink { DayDetailView(db: db, day: r) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(subtitle(r)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                    Text("\(r.runs.count)회 · \(RecordFormat.km(r.runs.reduce(0) { $0 + $1.distance }))")
                        .font(.footnote).foregroundStyle(Color.secondaryText).monospacedDigit()
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
            }
            .card()
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }

    private func photoSlot(_ r: Stats.Day, titled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if titled { Text(Resort.name(r.resortId)).font(.footnote).foregroundStyle(Color.secondaryText) }
            if let img = large[r.id] ?? thumbs[r.id] {
                Color.clear
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay { Image(uiImage: img).resizable().scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .accessibilityElement()
                    .accessibilityLabel("\(Self.dayTitle.string(from: selected)) \(Resort.name(r.resortId)) 사진")
                    .accessibilityAddTraits(.isImage)
                    .overlay(alignment: .topTrailing) {
                        Menu {
                            Button("바꾸기", systemImage: "photo") { pickPhoto(r) }
                            Button("빼기", systemImage: "trash", role: .destructive) { removePhoto(r) }
                        } label: {
                            Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundStyle(Color.primaryText)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(10)
                        .accessibilityLabel("사진 바꾸기 또는 빼기")
                    }
            } else {
                Button { pickPhoto(r) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus").font(.title2).accessibilityHidden(true)
                        Text("이날 사진 붙이기").font(.body.weight(.semibold))
                        Text("한 장 · 이 기기에만 저장돼요").font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                    .foregroundStyle(Color.accentText)
                    .dashedBox(minHeight: 160)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 고른 날 카드의 큰 하강 숫자 (글씨 크기 따라 커진다)
private struct BigCount: View {
    let runs: Int
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 64

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(runs)").font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
            Text("회").font(.title3.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("하강 \(runs)회")
    }
}

/// 고른 주 막대 위치 (카드 아래 꺾쇠)
private struct SelectedBar: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}
