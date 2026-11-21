import SwiftUI
import UIKit

/// S9 시즌 기록 탭 (R55 확정 v13; R6, R8, R36, R53). 홈 구조: 시즌 캡슐, 요약, 시즌권 캡슐, 넘기는 카드(SeasonCards.order).
/// 방문일 0일 판은 아직 그리지 않아 임시로 "0일 방문"과 카드만 보인다(todo).
struct SeasonView: View {
    let db: AppDatabase
    @Environment(SeasonTicket.self) private var ticket
    @State private var days: [Stats.Day] = []
    @State private var passes: [(pass: SeasonPass, resorts: [String])] = []
    @State private var season = HomeData.currentSeason()
    @State private var goal: SeasonGoal?
    /// 마지막 기록: 끝난 기록이 있는 가장 최근 방문일
    @State private var last: Stats.Day?
    /// 기록 달력 카드 주의 사진 (달력 날짜 00:00 → 작은 사진)
    @State private var photos: [Date: UIImage] = [:]
    @State private var editingGoal = false
    @State private var showTicket = false
    @State private var pastNote = false
    /// 시트를 열 때 다시 읽은 이번 시즌 (화면이 시즌을 넘겨 살아 있어도 맞게)
    @State private var goalSeason = HomeData.currentSeason()
    /// 넘기는 카드와 지금 보이는 카드(목표를 정해 카드가 바뀌어도 같은 카드에 머문다)
    @State private var list: [SeasonCards.Card] = []
    @State private var page: SeasonCards.Card?
    /// load()에서 한 번 계산
    @State private var totals = Stats.Totals()
    @State private var passValue: PassValue.Result?
    @State private var recapCount = 0
    @ScaledMetric(relativeTo: .largeTitle) private var bigSize = 64
    @ScaledMetric(relativeTo: .title) private var unitSize = 28

    private var mine: [Stats.Day] { Stats.days(days, inSeason: season) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    summary(totals)
                    cards
                }
                .foregroundStyle(Color.primaryText)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(FadeBackground())
            .startBarInset()
            .toolbar(.hidden, for: .navigationBar)
            // 화면에 돌아올 때마다 다시 읽는다(S8에서 지우거나 사진을 바꿀 수 있음)
            .task(id: season) { await load() }
            .onChange(of: season) { page = nil }
            .sheet(isPresented: $showTicket) { SeasonTicketView() }
            .sheet(isPresented: $editingGoal, onDismiss: { goal = SeasonGoal.load(season: season); reorder() }) {
                let t = Stats.totals(Stats.days(days, inSeason: goalSeason))
                SeasonGoalSheet(season: goalSeason, visitDays: t.visitDays, runs: t.runs, initial: SeasonGoal.load(season: goalSeason))
            }
            .alert(SeasonRecap.pastSeasonNote, isPresented: $pastNote) { Button("확인", role: .cancel) {} }
        }
    }

    private func load() async {
        days = await RecordLoader.days(db)
        passes = (try? db.passes(season: season)) ?? []
        goal = SeasonGoal.load(season: season)
        let mine = self.mine
        // 진행 중인 기록만 있는 오늘은 S6가 비어 보여 건너뛴다
        last = mine.filter(\.isVisit).sorted { $0.date > $1.date }
            .first { !((try? db.recordings(of: $0)) ?? []).isEmpty }
        // 한 날 두 리조트면 S8과 같이 하강이 많은 기록의 사진
        var p: [Date: UIImage] = [:]
        for d in RecordCalendar.days(mine, in: RecordCalendar.weekInterval(stripWeek)).sorted(by: { $0.runs.count > $1.runs.count }) {
            let k = RecordCalendar.dayStart(d.date)
            if p[k] == nil { p[k] = DayPhoto.image(d, maxPixel: 120) }
        }
        photos = p
        totals = Stats.totals(mine)
        passValue = PassValue.compute(passes, days: days, season: season)
        recapCount = SeasonRecapView.cards(days: days, season: season, passes: passes).count
        reorder()
    }

    private func reorder() {
        list = SeasonCards.order(hasGoal: goal != nil, canSetGoal: season == HomeData.currentSeason(),
                                 passIds: passes.map(\.pass.id), final: SeasonRecap.isFinal(season: season))
        if page.map(list.contains) != true { page = list.first }
    }

    private var seasons: [String] {
        Set(days.compactMap { Stats.season(of: $0.date) } + [HomeData.currentSeason()]).sorted(by: >)
    }

    // MARK: 위: 시즌 캡슐

    private var header: some View {
        HStack {
            Menu {
                Picker("시즌", selection: $season) {
                    ForEach(seasons, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("\(season) 시즌").monospacedDigit()
                    Image(systemName: "chevron.down").font(.footnote.weight(.bold)).accessibilityHidden(true)
                }
                .font(.headline).foregroundStyle(Color.primaryText)
                .padding(.horizontal, 16).frame(minHeight: 44)
                .glassCapsule()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("시즌 \(season)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 10)
    }

    // MARK: 요약

    private func summary(_ t: Stats.Totals) -> some View {
        let resorts = Stats.totalsByResort(mine).filter { $0.value.visitDays > 0 }
            .sorted { ($0.value.visitDays, $0.value.runs) > ($1.value.visitDays, $1.value.runs) }
            .map { Resort.name($0.key) }
        return VStack(alignment: .leading, spacing: 4) {
            if let last {
                NavigationLink { DayDetailView(db: db, day: last) } label: {
                    HStack(spacing: 4) {
                        Text("마지막 기록 · \(RecordFormat.monthDay(last.date)) \(Resort.name(last.resortId))")
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(t.visitDays)일").font(.system(size: bigSize, weight: .bold)).foregroundStyle(Color.accentText)
                    Text("방문").font(.system(size: unitSize, weight: .bold))
                }
                .monospacedDigit()
                Text("하강 \(Text("\(t.runs)회").bold()) · 거리 \(Text(RecordFormat.km(t.distance)).bold()) · 고도차 \(Text(RecordFormat.km(t.drop)).bold())")
                    .font(.subheadline).monospacedDigit()
                if !resorts.isEmpty {
                    // 많으면 방문일 순 3곳 + "외 n곳" 한 줄. 읽기는 전체
                    Label(resorts.prefix(3).joined(separator: " · ") + (resorts.count > 3 ? " 외 \(resorts.count - 3)곳" : ""),
                          systemImage: "mountain.2")
                        .font(.subheadline).foregroundStyle(Color.secondaryText).lineLimit(1)
                        .accessibilityLabel(resorts.joined(separator: ", "))
                }
            }
            .accessibilityElement(children: .combine)
            NavigationLink { SeasonPassListView(db: db, season: season) } label: {
                HStack(spacing: 6) {
                    Text(passes.isEmpty ? "시즌권 등록" : "시즌권 관리")
                    Image(systemName: passes.isEmpty ? "plus" : "chevron.right").font(.footnote.weight(.bold)).accessibilityHidden(true)
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText)
                .padding(.horizontal, 16).frame(minHeight: 44)
                .glassCapsule()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("시즌권 관리")
            .padding(.top, 10)
        }
        .padding(.horizontal, 20).padding(.bottom, 22)
    }

    // MARK: 넘기는 카드

    private var cards: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(list, id: \.self) { card in
                        cardView(card).frame(width: 318).id(card)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $page)

            HStack(spacing: 8) {
                ForEach(list, id: \.self) { card in
                    Circle().fill(card == (page ?? list.first) ? Color.accentText : Color.cardBorder).frame(width: 7, height: 7)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func cardView(_ card: SeasonCards.Card) -> some View {
        switch card {
        case .calendar: calendarCard
        case .goal: goalCard
        case .goalEmpty:
            Button { openGoal() } label: {
                EmptyCard(icon: "target", title: "목표 정하기", note: "방문일이나 하강 횟수 목표를 정해 보세요")
            }
            .buttonStyle(.plain)
        case .recap: recapCard
        case .pass(let id):
            if let p = passes.first(where: { $0.pass.id == id }), let value = passValue {
                passCard(name: p.pass.name, value: value.perPass[id] ?? nil, ticket: value.ticketValue[id] ?? 0)
            }
        case .passTotal:
            if let value = passValue {
                passCard(name: "시즌권 전체", value: value.total, ticket: value.ticketValue.values.reduce(0, +))
            }
        case .passEmpty:
            NavigationLink { SeasonPassListView(db: db, season: season) } label: {
                EmptyCard(icon: "ticket", title: "시즌권 등록", note: "가격을 넣으면 1회 방문당 금액을 계산해요")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 기록 달력

    /// 이번 주. 지난 시즌이면 그 시즌 마지막 주
    private var stripWeek: Date {
        RecordCalendar.weeks(season: season).last ?? RecordCalendar.weekStart(BusinessDay.start(of: .now))
    }

    private var calendarCard: some View {
        let week = stripWeek
        let today = RecordCalendar.dayStart(BusinessDay.start(of: .now))
        let isThis = week == RecordCalendar.weekStart(today)
        let inWeek = RecordCalendar.days(mine, in: RecordCalendar.weekInterval(week))
        let t = Stats.totals(inWeek)
        let prevStart = RecordCalendar.cal.date(byAdding: .day, value: -7, to: week)!
        let prev = Stats.totals(RecordCalendar.days(mine, in: RecordCalendar.weekInterval(prevStart)))
        let ridden = Set(inWeek.filter(\.isVisit).map { RecordCalendar.dayStart($0.date) })
        let footer = "\(isThis ? "이번 주" : "마지막 주") \(t.visitDays)일 · \(t.runs)회 · \(isThis ? "지난주" : "전 주") \(prev.runs)회"
        return NavigationLink { RecordCalendarView(db: db, season: season) } label: {
            CardShell(icon: "calendar", title: "기록 달력", accessory: Text("주 · 월 · 시즌 \(Image(systemName: "chevron.right"))"),
                      footer: Text(footer)) {
                HStack(spacing: 0) {
                    ForEach(Array(RecordCalendar.weekDays(week).enumerated()), id: \.offset) { i, d in
                        dayCell(d, weekday: i, ridden: ridden.contains(d), today: d == today, future: d > today)
                    }
                }
            }
            .accessibilityLabel("기록 달력, \(footer)")
        }
        .buttonStyle(.plain)
    }

    private func dayCell(_ d: Date, weekday: Int, ridden: Bool, today: Bool, future: Bool) -> some View {
        let photo = photos[d]
        let shape = RoundedRectangle(cornerRadius: photo == nil ? 18 : 10)
        return VStack(spacing: 6) {
            Text(["일", "월", "화", "수", "목", "금", "토"][weekday]).font(.caption).foregroundStyle(Color.secondaryText)
            ZStack {
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFill()
                } else if ridden {
                    Color.accentFill
                }
                Text("\(RecordCalendar.cal.component(.day, from: d))")
                    .font(.subheadline.weight(ridden ? .bold : .regular)).monospacedDigit()
                    .foregroundStyle(photo != nil ? Color.white : ridden ? Color.onAccent : Color.primaryText)
                    .shadow(color: photo != nil ? .black.opacity(0.6) : .clear, radius: 2)
            }
            .frame(width: 36, height: 36)
            .clipShape(shape)
            .overlay { if today { shape.strokeBorder(Color.accentText, lineWidth: 2) } }
        }
        .frame(maxWidth: .infinity)
        .opacity(future ? 0.4 : 1)
    }

    // MARK: 시즌 목표 (R36, 무료라 자물쇠 없음)

    private func openGoal() {
        goalSeason = HomeData.currentSeason()
        editingGoal = true
    }

    @ViewBuilder private var goalCard: some View {
        let t = totals
        let p = goal?.progress(visitDays: t.visitDays, runs: t.runs)
        let current = season == HomeData.currentSeason()
        let left = [p?.days.map { "\($0.left)일" }, p?.runs.map { "\($0.left)회" }].compactMap { $0 }
        let done = (p?.days?.done ?? true) && (p?.runs?.done ?? true)
        let shell = CardShell(icon: "target", title: "시즌 목표",
                              footer: current ? Text(done ? "목표를 모두 이뤘어요" : "\(left.joined(separator: " · ")) 남았어요") : nil) {
            VStack(alignment: .leading, spacing: 14) {
                if let d = p?.days { goalBar("방문일", unit: "일", d, cells: true) }
                if let r = p?.runs { goalBar("하강", unit: "회", r, cells: false) }
            }
        }
        if current {
            Button { openGoal() } label: { shell }.buttonStyle(.plain)
        } else {
            shell
        }
    }

    private func goalBar(_ name: String, unit: String, _ x: SeasonGoal.Progress, cells: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).fontWeight(.semibold)
                if x.done { Text("\(Image(systemName: "checkmark")) 달성").fontWeight(.semibold).foregroundStyle(Color.accentText) }
                Spacer(minLength: 8)
                Text("\(Text("\(x.value)").fontWeight(.semibold).foregroundStyle(Color.primaryText)) / \(x.target)\(unit)")
                    .foregroundStyle(Color.secondaryText).monospacedDigit()
            }
            .font(.subheadline)
            // 방문일은 하루 한 칸. 칸이 너무 잘아지면 막대로
            if cells && x.target <= 30 {
                HStack(spacing: 3) {
                    ForEach(0..<x.target, id: \.self) { i in
                        Capsule().fill(i < x.value ? Color.accentFill : Color.surface).frame(height: 8)
                    }
                }
            } else {
                Capsule().fill(Color.surface).frame(height: 8)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in Capsule().fill(Color.accentFill).frame(width: g.size.width * x.fraction) }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(x.done ? "\(name) 목표 \(x.target)\(unit), \(x.value)\(unit)로 달성" : "\(name) \(x.target)\(unit) 중 \(x.value)\(unit)")
    }

    // MARK: 결산 (R53)

    @ViewBuilder private var recapCard: some View {
        let final = SeasonRecap.isFinal(season: season)
        let title = final ? "최종 결산" : "지금까지 결산"
        let icon = "rectangle.portrait.on.rectangle.portrait"
        if totals.visitDays == 0 {
            CardShell(icon: icon, title: title) {
                Text("첫 기록을 남기면 결산을 볼 수 있어요").font(.headline).foregroundStyle(Color.secondaryText)
            }
            .opacity(0.6)
        } else {
            let count = recapCount
            let lock = SeasonRecap.lock(season: season, owned: ticket.seasons, current: SeasonTicket.season(purchase: .now))
            let big = VStack(alignment: .leading, spacing: 0) {
                Text("\(count)장").font(.largeTitle.bold()).monospacedDigit().foregroundStyle(Color.accentText)
                Text("\(season) 시즌 카드").font(.subheadline).foregroundStyle(Color.secondaryText)
            }
            if lock == .open {
                NavigationLink { SeasonRecapView(days: days, season: season, passes: passes) } label: {
                    CardShell(icon: icon, title: title, footer: Text("넘겨 보고 이미지로 공유해요")) { big }
                }
                .buttonStyle(.plain)
            } else {
                // 이용권이 없으면 결산 대신 이용권 화면 (2026-11-17)
                Button { if lock == .pastSeason { pastNote = true } else { showTicket = true } } label: {
                    CardShell(icon: icon, title: title, accessory: Text("\(Image(systemName: "lock.fill")) 이용권"),
                              footer: Text(lock == .pastSeason ? SeasonRecap.pastSeasonNote : "첫 카드 · 나머지 \(max(count - 1, 0))장은 시즌 이용권")) { big }
                }
                .buttonStyle(.plain)
                .accessibilityHint("시즌 이용권 필요")
            }
        }
    }

    // MARK: 시즌권 (R8)

    private func passCard(name: String, value: PassValue.Value?, ticket: Int) -> some View {
        NavigationLink { SeasonPassListView(db: db, season: season) } label: {
            CardShell(icon: "ticket", title: name, accessory: Text("\(value?.visits ?? 0)일 방문"),
                      footer: value.map { Text("한 번 더 가면 \(RecordFormat.won($0.price / ($0.visits + 1)))") }) {
                VStack(alignment: .leading, spacing: 0) {
                    if let value {
                        Text("1회 방문당").font(.subheadline).foregroundStyle(Color.secondaryText)
                        Text(RecordFormat.won(Int(value.perVisit.rounded()))).font(.largeTitle.bold()).monospacedDigit().foregroundStyle(Color.accentText)
                        let saved = ticket - value.price
                        Text(saved > 0 ? "리프트권보다 \(RecordFormat.won(saved)) 아꼈어요" : "리프트권이었다면 \(RecordFormat.won(ticket))")
                            .font(.subheadline).foregroundStyle(Color.secondaryText).monospacedDigit()
                    } else {
                        Text("방문 전").font(.largeTitle.bold()).foregroundStyle(Color.accentText)
                        Text("방문하면 1회 방문당 금액을 계산해요").font(.subheadline).foregroundStyle(Color.secondaryText)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// S9 카드 (홈 카드와 같은 틀): 폭 318(밖에서), 최소 높이 240, 안쪽 여백 20, 아이콘 원 36 + 제목, 아래 줄은 위 구분선
private struct CardShell<Content: View>: View {
    var icon: String
    var title: String
    var accessory: Text?
    var footer: Text?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                IconCircle(systemName: icon, size: 36)
                Text(title).font(.headline).foregroundStyle(Color.primaryText).lineLimit(1)
                Spacer(minLength: 4)
                accessory?.font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 12)
            content
            Spacer(minLength: 12)
            if let footer {
                Divider().overlay(Color.cardBorder)
                footer.font(.subheadline).foregroundStyle(Color.secondaryText).monospacedDigit().padding(.top, 12)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.cardBorder))
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

/// 빈 카드(목표·시즌권 없음): 점선 테두리, 큰 안내 글, 강조색 + 버튼
private struct EmptyCard: View {
    var icon: String
    var title: String
    var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            IconCircle(systemName: icon, size: 36)
            Spacer(minLength: 12)
            Text(title).font(.title2.bold()).foregroundStyle(Color.primaryText)
            Text(note).font(.subheadline).foregroundStyle(Color.secondaryText)
            HStack {
                Spacer()
                Image(systemName: "plus").font(.title3.weight(.bold)).foregroundStyle(Color.onAccent)
                    .frame(width: 44, height: 44).background(Color.accentFill, in: Circle())
                    .accessibilityHidden(true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.cardBorder, style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}
