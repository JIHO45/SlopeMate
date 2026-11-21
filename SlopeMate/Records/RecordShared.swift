import SwiftUI

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

/// S8 기록 달력·S9·S10이 함께 쓰는 하루 기록 목록. 지도는 메인에서 받고, 판정 결과 읽기는 뒤에서 한다.
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
    /// "15분", "1시간", "1시간 20분". 1분 미만은 1분
    static func duration(_ sec: TimeInterval) -> String {
        let m = max(1, Int((sec / 60).rounded()))
        return m < 60 ? "\(m)분" : m % 60 == 0 ? "\(m / 60)시간" : "\(m / 60)시간 \(m % 60)분"
    }
    /// 하루의 기록 시간 글자. 한 번이면 "22:28~23:55 기록". 여러 번이면 껐다 켠 사이를 뺀 합계 "기록 2회 · 총 15분"과
    /// 첫 시작~마지막 종료(작은 글씨용). 기록 중 수신이 끊긴 시간은 빼지 않는다(목록의 "기록 없음" 행과 숫자가 어긋나지 않게)
    static func recorded(_ spans: [DateInterval]) -> (line: String, range: String?)? {
        guard let first = spans.map(\.start).min(), let last = spans.map(\.end).max() else { return nil }
        let range = "\(time(first))~\(time(last))"
        if spans.count == 1 { return ("\(range) 기록", nil) }
        return ("기록 \(spans.count)회 · 총 \(duration(spans.reduce(0) { $0 + $1.duration }))", range)
    }
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
        Timetable.session(at: run.start, resortId: resortId, timetables: ServerConfig.timetables)
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
