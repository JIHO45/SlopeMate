import SwiftUI

/// S9 시즌 기록 탭 (확정 v1, 빈 상태 v1, 이용권 줄 v3, 목표 줄 v1; R6, R8, R53, R36). 시즌 고르기, 방문일·횟수·거리, 시즌권 카드, 리조트별 막대.
struct SeasonView: View {
    let db: AppDatabase
    @Environment(SeasonTicket.self) private var ticket
    @State private var days: [Stats.Day] = []
    @State private var passes: [(pass: SeasonPass, resorts: [String])] = []
    @State private var season = HomeData.currentSeason()
    @State private var goal: SeasonGoal?
    @State private var editingGoal = false
    @State private var showTicket = false
    @State private var pastNote = false
    /// 시트를 열 때 다시 읽은 이번 시즌 (화면이 시즌을 넘겨 살아 있어도 맞게)
    @State private var goalSeason = HomeData.currentSeason()
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                content.padding(.bottom, 24)
            }
            .background(FadeBackground())
            .startBarInset()
            .navigationTitle("시즌")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { seasonMenu } }
            .task(id: season) { await load() }
            .sheet(isPresented: $showTicket) { SeasonTicketView() }
            .alert(SeasonRecap.pastSeasonNote, isPresented: $pastNote) { Button("확인", role: .cancel) {} }
        }
    }

    private func load() async {
        days = await RecordLoader.days(db)
        passes = (try? db.passes(season: season)) ?? []
        goal = SeasonGoal.load(season: season)
    }

    private var seasons: [String] {
        Set(days.compactMap { Stats.season(of: $0.date) } + [HomeData.currentSeason()]).sorted(by: >)
    }

    private var seasonMenu: some View {
        Menu {
            Picker("시즌", selection: $season) {
                ForEach(seasons, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(season).monospacedDigit()
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .font(.subheadline)
        }
        .accessibilityLabel("시즌 \(season)")
    }

    @ViewBuilder private var content: some View {
        let mine = Stats.days(days, inSeason: season)
        let t = Stats.totals(mine)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("방문일").font(.headline)
                (Text("\(t.visitDays)").font(.system(size: 64, weight: .bold)) + Text("일").font(.system(size: 28, weight: .bold)))
                    .foregroundStyle(Color.accentText).monospacedDigit()
                Text("\(t.runs)회 · \(RecordFormat.km(t.distance))").font(.subheadline).foregroundStyle(Color.secondaryText)
            }
            .padding(.horizontal, 20).padding(.top, 8)
            .accessibilityElement(children: .combine)

            recapCard(t).padding(.top, 16)

            if t.visitDays == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "figure.skiing.downhill").font(.title).foregroundStyle(Color.accentText).accessibilityHidden(true)
                    Text("이번 시즌 첫 기록을 남겨 보세요").font(.body.weight(.semibold)).multilineTextAlignment(.center)
                }
                .padding(.vertical, 28).padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16).padding(.top, 12)
                passCards().padding(.top, 12)
                linkCard(showRecords: !days.isEmpty).padding(.top, 12)
            } else {
                passCards().padding(.top, 12)
                Text("리조트별").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                resortBars(mine, total: t.visitDays)
                linkCard(showRecords: true).padding(.top, 12)
            }
        }
        .foregroundStyle(Color.primaryText)
    }

    // MARK: 결산 (S9 v3 이용권 줄)

    /// 방문일 숫자 아래 카드. 결산 줄(이용권이 없으면 자물쇠, 누르면 이용권 화면)과 시즌 목표 줄.
    private func recapCard(_ t: Stats.Totals) -> some View {
        let visitDays = t.visitDays
        let final = SeasonRecap.isFinal(season: season)
        let title = final ? "최종 결산 보기" : "지금까지 결산 보기"
        return VStack(spacing: 0) {
            if visitDays == 0 {
                recapRow(title, note: Text("첫 기록을 남기면 결산을 볼 수 있어요"), chevron: false)
                    .opacity(0.6)
            } else {
                let lock = SeasonRecap.lock(season: season, owned: ticket.seasons, current: SeasonTicket.season(purchase: .now))
                if lock == .open {
                    NavigationLink { SeasonRecapView(days: days, season: season, passes: passes) } label: {
                        recapRow(title, note: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    // 이용권이 없으면 결산 대신 이용권 화면 (2026-11-17)
                    Button { if lock == .pastSeason { pastNote = true } else { showTicket = true } } label: {
                        recapRow(title, note: Text(lock == .pastSeason ? SeasonRecap.pastSeasonNote : "시즌 이용권으로 볼 수 있어요"),
                                 chevron: false, locked: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title), 시즌 이용권 필요")
                }
            }
            goalRow(t)
        }
        .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
        .padding(.horizontal, 16)
    }

    // MARK: 시즌 목표 (R36 v1, 무료라 자물쇠 없음)

    /// 이번 시즌은 누르면 시트. 지난 시즌은 저장된 목표가 있을 때만 읽기 전용으로.
    @ViewBuilder private func goalRow(_ t: Stats.Totals) -> some View {
        let current = season == HomeData.currentSeason()
        if current || goal != nil {
            Divider().overlay(Color.seasonRowSeparator)
            if current {
                Button {
                    goalSeason = HomeData.currentSeason()
                    editingGoal = true
                } label: { goalRowContent(t, chevron: true) }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $editingGoal, onDismiss: { goal = SeasonGoal.load(season: season) }) {
                        SeasonGoalSheet(season: goalSeason, visitDays: t.visitDays, runs: t.runs, initial: SeasonGoal.load(season: goalSeason))
                    }
            } else {
                goalRowContent(t, chevron: false)
            }
        }
    }

    @ViewBuilder private func goalRowContent(_ t: Stats.Totals, chevron: Bool) -> some View {
        let p = goal?.progress(visitDays: t.visitDays, runs: t.runs)
        let chev = Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
            .opacity(chevron ? 1 : 0).accessibilityHidden(true)
        if let p, let d = p.days, let r = p.runs {
            // 두 줄
            HStack(alignment: .top, spacing: 12) {
                IconCircle(systemName: "target", size: 36)
                VStack(alignment: .leading, spacing: 10) {
                    Text("시즌 목표").font(.body.weight(.semibold)).padding(.bottom, -2)
                    goalBar("방문일", unit: "일", d)
                    goalBar("하강", unit: "회", r)
                }
                chev.frame(maxHeight: .infinity)
            }
            .padding(.leading, 16).padding(.trailing, 12).padding(.top, 14).padding(.bottom, 16)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        } else if let p, let x = p.days ?? p.runs {
            // 한 줄
            let (name, unit) = p.days != nil ? ("방문일", "일") : ("하강", "회")
            HStack(spacing: 12) {
                IconCircle(systemName: "target", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("시즌 목표 · \(name) \(x.target)\(unit)").font(.body.weight(.semibold))
                    bar(x).padding(.vertical, 4)
                        .accessibilityLabel(barLabel(name, unit, x))
                    Group {
                        if x.done {
                            Text("\(x.value)\(unit) · ") + Text(Image(systemName: "checkmark")).fontWeight(.bold).foregroundStyle(Color.accentText)
                                + Text(" 달성").fontWeight(.semibold).foregroundStyle(Color.accentText)
                        } else if chevron {
                            Text("\(x.value)\(unit) · \(x.left)\(unit) 남음")
                        } else {
                            // 지난 시즌 읽기 전용: 남음 없이
                            Text("\(x.value)\(unit) / \(x.target)\(unit)")
                        }
                    }
                    .font(.footnote).foregroundStyle(Color.secondaryText).monospacedDigit()
                    .accessibilityHidden(true)
                }
                chev
            }
            .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 10)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        } else {
            recapRow("목표 정하기", icon: "target", note: Text("방문일이나 하강 횟수 목표를 정해 보세요"), chevron: true)
        }
    }

    private func goalBar(_ name: String, unit: String, _ x: SeasonGoal.Progress) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            let title = Text(name).fontWeight(.semibold)
            let done = (Text(Image(systemName: "checkmark")).fontWeight(.bold) + Text(" 달성").fontWeight(.semibold))
                .foregroundStyle(Color.accentText)
            let count = (Text("\(x.value)").fontWeight(.semibold).foregroundStyle(Color.primaryText) + Text(" / \(x.target)\(unit)"))
                .foregroundStyle(Color.secondaryText).monospacedDigit()
            // 접근성 글씨에서는 한 줄에 하나씩 (달성, 숫자를 아랫줄로)
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        if x.done { done }
                        count
                    }
                } else {
                    HStack {
                        title
                        if x.done { done.padding(.leading, 4) }
                        Spacer(minLength: 8)
                        count
                    }
                }
            }
            .font(.subheadline)
            .accessibilityHidden(true)
            bar(x).accessibilityLabel(barLabel(name, unit, x))
        }
    }

    private func barLabel(_ name: String, _ unit: String, _ x: SeasonGoal.Progress) -> String {
        x.done ? "\(name) 목표 \(x.target)\(unit), \(x.value)\(unit)로 달성" : "\(name) \(x.target)\(unit) 중 \(x.value)\(unit)"
    }

    private func bar(_ x: SeasonGoal.Progress) -> some View {
        Capsule().fill(Color.surface).frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { g in Capsule().fill(Color.accentFill).frame(width: g.size.width * x.fraction) }
            }
            .accessibilityElement()
    }

    private func recapRow(_ title: String, icon: String = "rectangle.portrait.on.rectangle.portrait", note: Text?, chevron: Bool, locked: Bool = false) -> some View {
        HStack(spacing: 12) {
            IconCircle(systemName: icon, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                if let note { note.font(.footnote).foregroundStyle(Color.secondaryText) }
            }
            Spacer(minLength: 0)
            if locked { Image(systemName: "lock.fill").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText).accessibilityHidden(true) }
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText) }
        }
        .foregroundStyle(Color.primaryText)
        .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 10)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }

    // MARK: 시즌권

    @ViewBuilder private func passCards() -> some View {
        if !passes.isEmpty {
            let r = PassValue.compute(passes, days: days, season: season)
            VStack(spacing: 12) {
                ForEach(passes, id: \.pass.id) { p in
                    let v = r.perPass[p.pass.id] ?? nil
                    passCard(head: "\(p.pass.name) · \(v?.visits ?? 0)일", value: v, ticket: r.ticketValue[p.pass.id] ?? 0)
                }
                if passes.count > 1 {
                    passCard(head: "시즌권 전체 · \(r.total?.visits ?? 0)일", value: r.total, ticket: r.ticketValue.values.reduce(0, +))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func passCard(head: String, value: PassValue.Value?, ticket: Int) -> some View {
        NavigationLink { SeasonPassListView(db: db, season: season) } label: {
            HStack(spacing: 14) {
                IconCircle(systemName: "ticket")
                VStack(alignment: .leading, spacing: 2) {
                    Text(head).font(.subheadline).foregroundStyle(Color.secondaryText)
                    if let value {
                        (Text("1회 방문당 ") + Text(RecordFormat.won(Int(value.perVisit.rounded()))).foregroundStyle(Color.accentText))
                            .font(.title3.weight(.bold)).monospacedDigit()
                        Text("리프트권이었다면 \(RecordFormat.won(ticket))").font(.subheadline).foregroundStyle(Color.secondaryText).monospacedDigit()
                    } else {
                        Text("아직 방문 기록이 없어요").font(.subheadline).foregroundStyle(Color.secondaryText)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.primaryText)
            .card(padding: 16)
        }
        .buttonStyle(.plain)
    }

    // MARK: 리조트별

    private func resortBars(_ mine: [Stats.Day], total: Int) -> some View {
        let by = Stats.totalsByResort(mine).filter { $0.value.visitDays > 0 }
            .sorted { ($0.value.visitDays, $0.value.runs) > ($1.value.visitDays, $1.value.runs) }
        return VStack(spacing: 0) {
            ForEach(Array(by.enumerated()), id: \.element.key) { i, e in
                if i > 0 { Divider().overlay(Color.seasonRowSeparator) }
                NavigationLink { RecordListView(db: db, resortId: e.key) } label: {
                    VStack(spacing: 8) {
                        HStack {
                            Text(Resort.name(e.key)).fontWeight(.semibold)
                            Spacer()
                            Text("\(e.value.visitDays)일 · \(e.value.runs)회 · \(RecordFormat.km(e.value.distance))")
                                .foregroundStyle(Color.secondaryText).monospacedDigit()
                        }
                        .font(.subheadline)
                        GeometryReader { g in
                            Capsule().fill(Color.surface)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Color.accentFill).frame(width: g.size.width * Double(e.value.visitDays) / Double(max(total, 1)))
                                }
                        }
                        .frame(height: 8)
                        .accessibilityHidden(true)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("\(Resort.name(e.key)) 기록 목록 열기")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
        .padding(.horizontal, 16)
    }

    // MARK: 기록 목록·시즌권 관리로 가는 줄

    private func linkCard(showRecords: Bool) -> some View {
        VStack(spacing: 0) {
            if showRecords {
                linkRow("list.bullet", "지난 기록") { RecordListView(db: db) }
                Divider().overlay(Color.seasonRowSeparator).padding(.leading, 54)
            }
            linkRow("ticket", "시즌권 관리") { SeasonPassListView(db: db, season: season) }
        }
        .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
        .padding(.horizontal, 16)
    }

    private func linkRow(_ icon: String, _ title: String, @ViewBuilder destination: @escaping () -> some View) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 14) {
                Image(systemName: icon).foregroundStyle(Color.accentText).frame(width: 24).accessibilityHidden(true)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
            }
            .foregroundStyle(Color.primaryText)
            .padding(.leading, 16).padding(.trailing, 12)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension Color {
    static let seasonRowSeparator = Color(light: 0xE3ECEF, dark: 0x23404B)
}
