import PhotosUI
import SwiftUI

/// S8 기록 달력 (R55): 주 · 월 · 시즌 보기, 하루 3D 그림과 대표 사진, 주 카드 ⋯에서 기록 지우기.
struct RecordCalendarView: View {
    enum Mode: Hashable { case week, month, season }

    let db: AppDatabase
    @State var season: String
    @State var mode = Mode.week
    @State var days: [Stats.Day]?
    @State var week: Date          // 일요일 00:00
    @State var selected: Date      // 달력 날짜 00:00
    @State var month: Date         // 달 1일 00:00
    @State var photoRev = 0        // 사진을 붙이거나 빼면 다시 읽게
    @State var thumbs: [String: UIImage] = [:]   // 시즌 하루 기록 사진 작은 판 (Stats.Day.id)
    @State var large: [String: UIImage] = [:]    // 고른 날 카드 2장 사진
    @State var photoDay: Stats.Day?
    @State var picking = false
    @State var pickerItem: PhotosPickerItem?
    @State var photoFailed = false
    @State var deleting: Stats.Day?
    @State var failed = false
    @Environment(Crews.self) private var crews: Crews?
    @Environment(SummarySync.self) private var summary: SummarySync?

    init(db: AppDatabase, season: String) {
        self.db = db
        _season = State(initialValue: season)
        let s = Self.start(season)
        _week = State(initialValue: s.week)
        _selected = State(initialValue: s.day)
        _month = State(initialValue: s.month)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("보기", selection: Binding(get: { mode }, set: { m in
                // 월로 바꾸면 고른 날이 든 달
                let sel = RecordCalendar.monthInterval(selected).start
                if m == .month, RecordCalendar.seasonMonths(season).contains(sel) { month = sel }
                mode = m
            })) {
                Text("주").tag(Mode.week)
                Text("월").tag(Mode.month)
                Text("시즌").tag(Mode.season)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)
            if let days {
                switch mode {
                case .week: weekView(days)
                case .month: monthView(days)
                case .season: seasonView(days)
                }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg)
        .navigationTitle("기록 달력")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            days = await RecordLoader.days(db, finishedOnly: true)
            settle()
        }
        .task(id: "\(season) \(photoRev) \(days?.count ?? -1)") {
            let mine = Stats.days(days ?? [], inSeason: season)
            thumbs = await Task.detached { Self.load(mine, 360) }.value
        }
        .task(id: "\(selected) \(photoRev) \(days?.count ?? -1)") {
            let recs = records(on: selected, days ?? [])
            large = await Task.detached { Self.load(recs, 1200) }.value
        }
        .photosPicker(isPresented: $picking, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in attach(item) }
        .alert(deleting.map { "\(RecordFormat.monthDay($0.date)) \(Resort.name($0.resortId)) 기록을 지울까요?" } ?? "",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { day in
            Button("취소", role: .cancel) {}
            Button("지우기", role: .destructive) { delete(day) }
        } message: { _ in
            Text("되돌릴 수 없어요.")
        }
        .alert("기록을 지우지 못했어요", isPresented: $failed) { Button("확인") {} }
        .alert("사진을 붙이지 못했어요", isPresented: $photoFailed) { Button("확인") {} }
    }

    // MARK: 상태

    var today: Date { RecordCalendar.dayStart(BusinessDay.start(of: .now)) }

    /// 시즌을 열 때: 이번 주(지난 시즌이면 마지막 주), 오늘이 그 주면 오늘
    static func start(_ season: String) -> (week: Date, day: Date, month: Date) {
        let today = RecordCalendar.dayStart(BusinessDay.start(of: .now))
        let week = RecordCalendar.weeks(season: season).last ?? RecordCalendar.weekStart(HomeData.seasonStart(season))
        let day = RecordCalendar.weekInterval(week).contains(today) ? today : week
        let months = RecordCalendar.seasonMonths(season)
        let m = RecordCalendar.monthInterval(day).start
        return (week, day, months.contains(m) ? m : months[0])
    }

    func show(season s: String) {
        season = s
        let v = Self.start(s)
        (week, selected, month) = (v.week, v.day, v.month)
        settle()
    }

    /// 기록을 읽은 뒤: 오늘이 고른 주에 없으면(지난 시즌) 시즌 마지막 기록 주로, 그 주 마지막 기록 날을 고른다
    func settle() {
        if !RecordCalendar.weekInterval(week).contains(today),
           let last = Stats.days(days ?? [], inSeason: season).map(\.date).max() {
            week = RecordCalendar.weekStart(last)
        }
        pick(week: week)
        let m = RecordCalendar.monthInterval(selected).start
        if RecordCalendar.seasonMonths(season).contains(m) { month = m }
    }

    /// 주를 고르면 그 주 마지막 기록 날, 없으면 오늘(이번 주) 또는 일요일
    func pick(week w: Date) {
        let i = RecordCalendar.weekInterval(w)
        week = w
        selected = RecordCalendar.days(Stats.days(days ?? [], inSeason: season), in: i).map { RecordCalendar.dayStart($0.date) }.max()
            ?? (i.contains(today) ? today : w)
    }

    func open(day d: Date) {
        week = RecordCalendar.weekStart(d)
        selected = d
        mode = .week
    }

    func records(on d: Date, _ all: [Stats.Day]) -> [Stats.Day] {
        RecordCalendar.days(all, in: DateInterval(start: d, duration: 24 * 3600)) // 한국은 서머타임 없음
            .sorted { $0.runs.count > $1.runs.count }
    }

    /// 메인 밖에서 부른다
    nonisolated static func load(_ days: [Stats.Day], _ maxPixel: Int) -> [String: UIImage] {
        var out: [String: UIImage] = [:]
        for d in days { out[d.id] = DayPhoto.image(d, maxPixel: maxPixel) }
        return out
    }

    // MARK: 사진·삭제

    func pickPhoto(_ day: Stats.Day) {
        photoDay = day
        picking = true
    }

    private func attach(_ item: PhotosPickerItem?) {
        guard let item, let day = photoDay else { return }
        pickerItem = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw DayPhoto.Undecodable() }
                try await Task.detached { try DayPhoto.save(data, for: day) }.value
                photoRev += 1
            } catch {
                photoFailed = true
            }
        }
    }

    func removePhoto(_ day: Stats.Day) {
        DayPhoto.delete(day)
        photoRev += 1
    }

    private func delete(_ day: Stats.Day) {
        do {
            try db.delete(day)
            days?.removeAll { $0.id == day.id }
            // 지운 하루가 크루 순위 합계에서도 바로 빠지게 (R15)
            if crews?.ids.isEmpty == false { summary?.sync() }
            DayPhoto.delete(day)
            DayStill.remove(day)
        } catch {
            failed = true
        }
    }

    // MARK: 공통 부품

    /// 제목 + 합계 줄, 양옆 이전·다음
    func navHeader(_ title: String, _ sub: String, unit: String, prev: (() -> Void)?, next: (() -> Void)?) -> some View {
        HStack(spacing: 4) {
            arrow("chevron.left", "이전 \(unit)", prev)
            VStack(spacing: 2) {
                Text(title).font(.title3.weight(.bold)).foregroundStyle(Color.primaryText)
                Text(sub).font(.subheadline).foregroundStyle(Color.secondaryText).monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            arrow("chevron.right", "다음 \(unit)", next)
        }
    }

    private func arrow(_ icon: String, _ label: String, _ action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentText)
        .disabled(action == nil)
        .opacity(action == nil ? 0.3 : 1)
        .accessibilityLabel(label)
    }

    static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

    private static func formatter(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "ko_KR")
        d.timeZone = TimeZone(identifier: "Asia/Seoul")
        d.dateFormat = f
        return d
    }
    /// "12월 20일 일요일"
    static let dayTitle = formatter("M월 d일 EEEE")
    /// "2026년 12월"
    static let yearMonth = formatter("yyyy년 M월")
}
