import SwiftUI

/// S9 시즌 기록 탭 (확정 v1, 빈 상태 v1; R6, R8). 시즌 고르기, 방문일·횟수·거리, 시즌권 카드, 리조트별 막대.
struct SeasonView: View {
    let db: AppDatabase
    @State private var days: [Stats.Day] = []
    @State private var passes: [(pass: SeasonPass, resorts: [String])] = []
    @State private var season = HomeData.currentSeason()

    var body: some View {
        NavigationStack {
            ScrollView {
                content.padding(.bottom, 24)
            }
            .background(FadeBackground())
            .navigationTitle("시즌")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { seasonMenu } }
            .task(id: season) { await load() }
        }
    }

    private func load() async {
        days = await RecordLoader.days(db)
        passes = (try? db.passes(season: season)) ?? []
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

            if t.visitDays == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "figure.skiing.downhill").font(.title).foregroundStyle(Color.accentText).accessibilityHidden(true)
                    Text("이번 시즌 첫 기록을 남겨 보세요").font(.body.weight(.semibold)).multilineTextAlignment(.center)
                }
                .padding(.vertical, 28).padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16).padding(.top, 24)
                passCards().padding(.top, 12)
                linkCard(showRecords: !days.isEmpty).padding(.top, 12)
            } else {
                passCards().padding(.top, 18)
                Text("리조트별").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                resortBars(mine, total: t.visitDays)
                linkCard(showRecords: true).padding(.top, 12)
            }
        }
        .foregroundStyle(Color.primaryText)
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
