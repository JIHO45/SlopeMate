import SwiftUI

/// S8 기록 목록 (B4 확정: v1, 빈 상태 v1, 삭제 확인 v2). 하루(영업일 × 리조트) 단위 행, 월별 묶음, 리조트 거르기, 밀어서 삭제.
struct RecordListView: View {
    let db: AppDatabase
    @State var resortId: String? = nil
    @State private var days: [Stats.Day]?
    @State private var deleting: Stats.Day?
    @State private var failed = false

    var body: some View {
        Group {
            if let days {
                if days.isEmpty {
                    RecordEmptyState(systemName: "list.bullet", text: "아직 기록이 없어요")
                } else {
                    list(days)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg)
        .navigationTitle("지난 기록")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let days, !days.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { filterMenu(days) }
            }
        }
        .task { days = await RecordLoader.days(db, finishedOnly: true) }
        .alert(deleting.map { "\(RecordFormat.monthDay($0.date)) \(Resort.name($0.resortId)) 기록을 지울까요?" } ?? "",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { day in
            Button("취소", role: .cancel) {}
            Button("지우기", role: .destructive) { delete(day) }
        } message: { _ in
            Text("되돌릴 수 없어요.")
        }
        .alert("기록을 지우지 못했어요", isPresented: $failed) { Button("확인") {} }
    }

    private func list(_ all: [Stats.Day]) -> some View {
        let shown = all.filter { resortId == nil || $0.resortId == resortId }
        let months = Dictionary(grouping: shown) { RecordFormat.month($0.date) }
        return List {
            ForEach(months.keys.sorted(by: >), id: \.self) { key in
                Section {
                    ForEach(months[key]!) { day in
                        NavigationLink { DayDetailView(db: db, day: day) } label: { RecordRow(day: day) }
                            .listRowBackground(Color.card)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
                            .swipeActions { Button("삭제", role: .destructive) { deleting = day } }
                    }
                } header: {
                    Text(RecordFormat.monthTitle(months[key]![0].date))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primaryText).textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func filterMenu(_ days: [Stats.Day]) -> some View {
        let ids = Set(days.map(\.resortId)).sorted { Resort.name($0) < Resort.name($1) }
        return Menu {
            Picker("리조트", selection: $resortId) {
                Text("모든 리조트").tag(String?.none)
                ForEach(ids, id: \.self) { Text(Resort.name($0)).tag(String?.some($0)) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(resortId.map { Resort.name($0) } ?? "모든 리조트")
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .font(.subheadline)
        }
        .accessibilityLabel("리조트 거르기, \(resortId.map { Resort.name($0) } ?? "모든 리조트")")
    }

    private func delete(_ day: Stats.Day) {
        do {
            try db.delete(day)
            days?.removeAll { $0.id == day.id }
        } catch {
            failed = true
        }
    }
}

private struct RecordRow: View {
    let day: Stats.Day

    var body: some View {
        let sessions = RecordFormat.sessionNames(day)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(RecordFormat.monthDayWeekday(day.date)).font(.subheadline.weight(.semibold))
                Text(([Resort.name(day.resortId)] + (sessions.isEmpty ? [] : [sessions])).joined(separator: " · "))
                    .font(.footnote).foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(day.runs.count)회").font(.subheadline.weight(.semibold))
                Text(RecordFormat.km(day.runs.reduce(0) { $0 + $1.distance })).font(.footnote).foregroundStyle(Color.secondaryText)
            }
            .monospacedDigit()
        }
        .foregroundStyle(Color.primaryText)
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
    }
}

/// 빈 상태: 72pt 원 아이콘 + 굵은 한 줄 (S8, S10 빈 상태 v1)
struct RecordEmptyState<Extra: View>: View {
    var systemName: String
    var text: String
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemName)
                .font(.title)
                .foregroundStyle(Color.accentText)
                .frame(width: 72, height: 72)
                .background(Color.surface, in: Circle())
                .accessibilityHidden(true)
            Text(text).font(.body.weight(.semibold)).multilineTextAlignment(.center).foregroundStyle(Color.primaryText)
            extra
        }
        .padding(.horizontal, 32)
    }
}

extension RecordEmptyState where Extra == EmptyView {
    init(systemName: String, text: String) { self.init(systemName: systemName, text: text) { EmptyView() } }
}

/// S8·S9·S10이 함께 쓰는 하루 기록 목록. 지도는 메인에서 받고, 판정 결과 읽기는 뒤에서 한다.
enum RecordLoader {
    /// 시즌 합계(S9·S10)는 홈과 같이 진행 중인 오늘 기록도 센다.
    /// 기록 목록(S8)은 끝난 기록만: 하루 기록(S6)·삭제가 끝난 기록만 다룬다.
    static func days(_ db: AppDatabase, finishedOnly: Bool = false) async -> [Stats.Day] {
        guard finishedOnly else {
            return await Task.detached { (try? HomeData.days(db, since: .distantPast)) ?? [] }.value
        }
        guard let recs = try? db.finishedRecordings() else { return [] }
        var maps: [String: SlopeMap] = [:]
        for id in Set(recs.map(\.resortId)) { maps[id] = SlopeMap.cached(resortId: id) }
        let m = maps
        return await Task.detached { (try? Stats.days(db.summaries(recs, maps: m))) ?? [] }.value
    }
}

/// B4 화면의 숫자·날짜 글자. 날짜는 한국 시간.
enum RecordFormat {
    private static func formatter(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "ko_KR")
        d.timeZone = TimeZone(identifier: "Asia/Seoul")
        d.dateFormat = f
        return d
    }
    private static let md = formatter("M월 d일"), mdw = formatter("M월 d일 (E)"), hm = formatter("HH:mm")
    private static let ym = formatter("yyyy-MM"), m = formatter("M월"), yM = formatter("yyyy년 M월")

    static func monthDay(_ d: Date) -> String { md.string(from: d) }
    static func monthDayWeekday(_ d: Date) -> String { mdw.string(from: d) }
    static func time(_ d: Date) -> String { hm.string(from: d) }
    static func month(_ d: Date) -> String { ym.string(from: d) }
    /// 이번 시즌이면 "12월", 아니면 "2025년 12월"
    static func monthTitle(_ d: Date) -> String {
        Stats.season(of: d) == Stats.season(of: BusinessDay.start(of: .now)) ? m.string(from: d) : yM.string(from: d)
    }

    /// 100km 미만은 소수 한 자리
    static func km(_ meters: Double) -> String {
        let k = meters / 1000
        return k < 100 ? String(format: "%.1fkm", k) : "\(Int(k.rounded()).formatted())km"
    }
    static func kmh(_ mps: Double) -> String { "\(Int((mps * 3.6).rounded()))km/h" }
    static func won(_ n: Int) -> String { "\(n.formatted())원" }

    static let sessionOrder: [SessionKind] = [.day, .night, .lateNight, .unclassified]
    static func sessionName(_ s: SessionKind) -> String {
        switch s {
        case .day: "주간"
        case .night: "야간"
        case .lateNight: "심야"
        case .unclassified: "미분류"
        }
    }
    static func session(_ run: RunDetector.Run, resortId: String) -> SessionKind? {
        Timetable.session(at: run.start, resortId: resortId, timetables: Timetable.all)
    }
    /// "주간·야간". 세션을 나누지 않는 리조트·날짜면 빈 문자열
    static func sessionNames(_ day: Stats.Day) -> String {
        let kinds = Set(day.runs.compactMap { session($0, resortId: day.resortId) })
        return sessionOrder.filter(kinds.contains).map { sessionName($0) }.joined(separator: "·")
    }

    /// 조사: 받침이 있으면 a("은"·"을"), 없으면 b
    static func josa(_ word: String, _ a: String, _ b: String) -> String {
        guard let s = word.unicodeScalars.last, (0xAC00...0xD7A3).contains(s.value) else { return a }
        return (s.value - 0xAC00) % 28 == 0 ? b : a
    }
}
