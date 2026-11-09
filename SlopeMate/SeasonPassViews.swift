import SwiftUI

/// S10 시즌권 관리 (확정: 관리 v2, 빈 상태 v1; R8). 시즌 합계, 시즌권마다 방문당 금액, 순서 바꾸기, 추가·수정 시트.
struct SeasonPassListView: View {
    let db: AppDatabase
    let season: String
    @State private var passes: [(pass: SeasonPass, resorts: [String])]?
    @State private var days: [Stats.Day] = []
    @State private var editing: PassSheet?

    private struct PassSheet: Identifiable {
        var pass: SeasonPass?
        var resorts: [String] = []
        let id = UUID()
    }

    var body: some View {
        Group {
            if let passes {
                if passes.isEmpty {
                    RecordEmptyState(systemName: "ticket", text: "시즌권 가격을 넣으면 1회 방문당 금액을 알려 드려요") {
                        Button("시즌권 추가") { editing = PassSheet() }
                            .buttonStyle(PrimaryButtonStyle())
                            .padding(.top, 8)
                    }
                } else {
                    list(passes)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg)
        .navigationTitle("시즌권")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let passes, !passes.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = PassSheet() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("시즌권 추가")
                }
            }
        }
        .sheet(item: $editing, onDismiss: reload) { s in
            PassEditView(db: db, original: s.pass, initialResorts: s.resorts, season: s.pass?.season ?? season)
                .id(s.id) // 시트마다 새 입력 상태
        }
        .task {
            reload()
            days = await RecordLoader.days(db)
        }
    }

    private func move(_ id: UUID, by d: Int) {
        guard var ids = passes?.map(\.pass.id), let i = ids.firstIndex(of: id), ids.indices.contains(i + d) else { return }
        ids.swapAt(i, i + d)
        try? db.reorderPasses(ids)
        reload()
    }

    private func reload() { passes = (try? db.passes(season: season)) ?? [] }

    private func list(_ passes: [(pass: SeasonPass, resorts: [String])]) -> some View {
        let r = PassValue.compute(passes, days: days, season: season)
        return List {
            Section {
                summary(passes, r).listRowBackground(Color.surface)
            }
            Section {
                ForEach(passes, id: \.pass.id) { p in
                    Button { editing = PassSheet(pass: p.pass, resorts: p.resorts) } label: {
                        passRow(p, value: r.perPass[p.pass.id] ?? nil, ticket: r.ticketValue[p.pass.id] ?? 0)
                    }
                    .listRowBackground(Color.card)
                    .accessibilityHint("시즌권 수정")
                    // 길게 눌러 끌기를 못 쓰는 VoiceOver용
                    .accessibilityAction(named: "위로 옮기기") { move(p.pass.id, by: -1) }
                    .accessibilityAction(named: "아래로 옮기기") { move(p.pass.id, by: 1) }
                }
                .onMove { from, to in
                    var ids = passes.map(\.pass.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    try? db.reorderPasses(ids)
                    reload()
                }
            } footer: {
                Text("한 리조트가 두 시즌권에 있으면 위에 있는 시즌권에만 세요. 길게 눌러 끌면 순서를 바꿀 수 있어요.")
                    .font(.footnote).foregroundStyle(Color.secondaryText)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .scrollContentBackground(.hidden)
    }

    /// "2026-27 시즌 · 3장 · 20일 · 1,320,000원". 2장 이상이면 전체 방문당 금액도.
    private func summary(_ passes: [(pass: SeasonPass, resorts: [String])], _ r: PassValue.Result) -> some View {
        let visits = r.total?.visits ?? r.perPass.values.compactMap { $0?.visits }.reduce(0, +)
        let price = passes.reduce(0) { $0 + $1.pass.price }
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(season) 시즌 · \(passes.count)장 · \(visits)일 · \(RecordFormat.won(price))")
                .font(.subheadline).foregroundStyle(Color.secondaryText).monospacedDigit()
            if let total = r.total {
                perVisit(total)
                Text("리프트권이었다면 \(RecordFormat.won(r.ticketValue.values.reduce(0, +)))")
                    .font(.subheadline).foregroundStyle(Color.secondaryText).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func perVisit(_ v: PassValue.Value) -> some View {
        (Text("1회 방문당 ") + Text(RecordFormat.won(Int(v.perVisit.rounded()))).foregroundStyle(Color.accentText))
            .font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(Color.primaryText)
    }

    private func passRow(_ p: (pass: SeasonPass, resorts: [String]), value: PassValue.Value?, ticket: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.pass.name).font(.body.weight(.semibold))
            Text("\(p.resorts.map { Resort.name($0) }.joined(separator: ", ")) · \(value?.visits ?? 0)일")
                .font(.footnote).foregroundStyle(Color.secondaryText)
                .padding(.bottom, 6)
            if let value {
                perVisit(value)
                Text("리프트권이었다면 \(RecordFormat.won(ticket))").font(.subheadline).foregroundStyle(Color.secondaryText).monospacedDigit()
            } else {
                Text("아직 방문 기록이 없어요").font(.subheadline).foregroundStyle(Color.secondaryText)
            }
        }
        .foregroundStyle(Color.primaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// S10 시즌권 추가·수정 시트 (확정: 추가 v2, 입력 오류 v2, 삭제 확인 v2).
struct PassEditView: View {
    let db: AppDatabase
    let original: SeasonPass?
    @State private var season: String
    @State private var name: String
    @State private var price: String
    @State private var dayPrice: String
    @State private var resorts: Set<String>
    @State private var others: [(pass: SeasonPass, resorts: [String])] = []
    @State private var showErrors = false
    @State private var confirmDelete = false
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    init(db: AppDatabase, original: SeasonPass?, initialResorts: [String], season: String) {
        self.db = db
        self.original = original
        _season = State(initialValue: season)
        _name = State(initialValue: original?.name ?? "")
        _price = State(initialValue: original.map { $0.price.formatted() } ?? "")
        _dayPrice = State(initialValue: original.map { $0.dayTicketPrice.formatted() } ?? "")
        _resorts = State(initialValue: Set(initialResorts))
    }

    private static func amount(_ s: String) -> Int { Int(s.filter(\.isNumber)) ?? 0 }
    private var nameError: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty }
    private var priceError: Bool { Self.amount(price) <= 0 }
    private var dayPriceError: Bool { Self.amount(dayPrice) <= 0 }

    /// 지금 시즌 앞뒤 한 시즌씩
    private var seasons: [String] {
        guard let y = Int(HomeData.currentSeason().prefix(4)) else { return [season] }
        return Set([y - 1, y, y + 1].map { String(format: "%d-%02d", $0, ($0 + 1) % 100) } + [season]).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("시즌") {
                        Menu {
                            Picker("시즌", selection: $season) { ForEach(seasons, id: \.self) { Text($0).tag($0) } }
                        } label: {
                            HStack {
                                Text(season).monospacedDigit()
                                Spacer()
                                Image(systemName: "chevron.down").font(.footnote.weight(.bold)).foregroundStyle(Color.secondaryText)
                            }
                            .foregroundStyle(Color.primaryText)
                            .padding(.leading, 16).padding(.trailing, 12)
                            .frame(height: 48)
                            .inputBox(error: false)
                        }
                        .accessibilityLabel("시즌, \(season)")
                    }
                    field("이름", error: showErrors && nameError ? "이름을 넣어 주세요" : nil) {
                        TextField("예: 하이원 시즌권", text: $name)
                            .padding(.horizontal, 16).frame(height: 48)
                            .inputBox(error: showErrors && nameError)
                    }
                    moneyField("가격", $price, error: showErrors && priceError)
                    moneyField("하루 리프트권 가격", $dayPrice, error: showErrors && dayPriceError)
                    resortPicker
                    if original != nil {
                        Button("시즌권 삭제") { confirmDelete = true }
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.passDangerText)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Color.passDangerFill, in: RoundedRectangle(cornerRadius: 14))
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.bg)
            .navigationTitle(original == nil ? "시즌권 추가" : "시즌권 수정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("취소")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) { Image(systemName: "checkmark") }
                        .accessibilityLabel("저장")
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .tint(Color.accentFill)
                        .foregroundStyle(Color.onAccent)
                }
            }
            .task(id: season) { others = ((try? db.passes(season: season)) ?? []).filter { $0.pass.id != original?.id } }
            .alert(deleteTitle, isPresented: $confirmDelete) {
                Button("취소", role: .cancel) {}
                Button("지우기", role: .destructive) { delete() }
            } message: {
                Text("1회 방문당 금액 계산에서 빠지고, 되돌릴 수 없어요.")
            }
            .alert("저장하지 못했어요", isPresented: $failed) { Button("확인") {} }
        }
    }

    /// "2026-27 시즌 '하이원 야간 시즌권'을 지울까요?"
    private var deleteTitle: String {
        let n = original?.name ?? name
        return "\(original?.season ?? season) 시즌 '\(n)'\(RecordFormat.josa(n, "을", "를")) 지울까요?"
    }

    private func field(_ label: String, error: String? = nil, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.semibold)).padding(.leading, 4)
            content()
            if let error { PassFieldError(text: error) }
        }
    }

    private func moneyField(_ label: String, _ text: Binding<String>, error: Bool) -> some View {
        field(label, error: error ? "0원보다 큰 금액을 넣어 주세요" : nil) {
            HStack {
                TextField("0", text: text)
                    .keyboardType(.numberPad)
                    .monospacedDigit()
                    .accessibilityLabel(label)
                    .onChange(of: text.wrappedValue) { _, v in
                        let digits = String(v.filter(\.isNumber).prefix(9))
                        let shown = Int(digits).map { $0.formatted() } ?? ""
                        if shown != v { text.wrappedValue = shown }
                    }
                Text("원").foregroundStyle(Color.secondaryText).accessibilityHidden(true)
            }
            .padding(.horizontal, 16).frame(height: 48)
            .inputBox(error: error)
        }
    }

    private var resortPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("대상 리조트").font(.subheadline.weight(.semibold)).padding(.leading, 4).padding(.bottom, 6)
            if showErrors && resorts.isEmpty { PassFieldError(text: "대상 리조트를 하나 이상 고르세요") }
            VStack(spacing: 0) {
                ForEach(Array(Resort.all.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { Divider().overlay(Color.passRowSeparator) }
                    let on = resorts.contains(r.id)
                    Button {
                        if on { resorts.remove(r.id) } else { resorts.insert(r.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Text(r.name).foregroundStyle(Color.primaryText)
                            Spacer()
                            if on {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.onAccent)
                                    .frame(width: 24, height: 24).background(Color.accentFill, in: Circle())
                            } else {
                                Circle().strokeBorder(Color.passUnchecked, lineWidth: 1.5).frame(width: 24, height: 24)
                            }
                        }
                        .padding(.horizontal, 16).frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
            ForEach(overlaps, id: \.self) { text in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Color.accentText).accessibilityHidden(true)
                    Text(text)
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 16))
                .padding(.top, 6)
            }
        }
    }

    /// "하이원은 이미 '하이원 시즌권'에 들어 있어요. 위에 있는 시즌권에만 세요."
    private var overlaps: [String] {
        Resort.all.filter { resorts.contains($0.id) }.compactMap { r in
            others.first { $0.resorts.contains(r.id) }.map {
                "\(r.name)\(RecordFormat.josa(r.name, "은", "는")) 이미 '\($0.pass.name)'에 들어 있어요. 위에 있는 시즌권에만 세요."
            }
        }
    }

    private func save() {
        showErrors = true
        guard !nameError, !priceError, !dayPriceError, !resorts.isEmpty else { return }
        let order = (others.map(\.pass.sortOrder).max() ?? -1) + 1  // 새 시즌권은 맨 아래. 고칠 때는 save가 원래 순서를 지킨다
        let pass = SeasonPass(id: original?.id ?? UUID(), season: season, name: name.trimmingCharacters(in: .whitespaces),
                              price: Self.amount(price), dayTicketPrice: Self.amount(dayPrice), sortOrder: order)
        do {
            try db.save(pass, resorts: Array(resorts))
            dismiss()
        } catch {
            failed = true
        }
    }

    private func delete() {
        guard let original else { return }
        do {
            try db.deletePass(original.id)
            dismiss()
        } catch {
            failed = true
        }
    }
}

private struct PassFieldError: View {
    var text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.footnote)
            .foregroundStyle(Color.passDangerText)
    }
}

private extension View {
    func inputBox(error: Bool) -> some View {
        background(Color.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(error ? Color.passDangerText : Color.cardBorder, lineWidth: error ? 2 : 1))
    }
}

private extension Color {
    static let passDangerText = Color(light: 0x8A1C1C, dark: 0xFFB4B4)
    static let passDangerFill = Color(light: 0xFDE8E8, dark: 0x3A1618)
    static let passUnchecked = Color(light: 0x7C949B, dark: 0x5A7680)
    static let passRowSeparator = Color(light: 0xE3ECEF, dark: 0x23404B)
}
