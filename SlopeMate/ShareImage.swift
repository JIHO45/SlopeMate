import SwiftUI
import UIKit

/// 하루 기록 공유 이미지 (R31; 확정 시안 공유 이미지 v2).
/// 1080×1350 한 장: 날짜·리조트, 하강 횟수·거리, 세션별 시간·횟수. 요약 데이터만 새로 그리므로
/// 지도·경로·좌표와 위치 메타데이터가 들어가지 않는다. 공유를 누를 때만 만든다.
enum ShareImage {
    struct Session: Equatable {
        var name: String     // "심야"
        var time: String?    // "22:40~다음 날 01:30", 미분류는 nil
        var runs: Int
    }

    struct Content: Equatable {
        var date: String     // "2026년 12월 6일 일요일"
        var resort: String
        var runs: Int
        var distance: String // "8.3"
        var sessions: [Session] // 시간표가 없어 세션을 나누지 않으면 빈 배열
    }

    private static let dateFormat: DateFormatter = {
        let d = DateFormatter()
        d.locale = Locale(identifier: "ko_KR")
        d.timeZone = TimeZone(identifier: "Asia/Seoul")
        d.dateFormat = "yyyy년 M월 d일 EEEE"
        return d
    }()

    static func content(_ day: Stats.Day, resort: String,
                       session: (RunDetector.Run) -> SessionKind? = { _ in nil }) -> Content {
        let kinds = day.runs.map(session)
        var sessions: [Session] = []
        if kinds.contains(where: { $0 != nil }) {
            for k in RecordFormat.sessionOrder {
                let mine = day.runs.indices.filter { (kinds[$0] ?? .unclassified) == k }.map { day.runs[$0] }
                guard let first = mine.first, let last = mine.map(\.end).max() else { continue }
                sessions.append(Session(name: RecordFormat.sessionName(k),
                                        time: k == .unclassified ? nil : span(first.start, last, day: day.date),
                                        runs: mine.count))
            }
        }
        let km = RecordFormat.km(Stats.totals([day]).distance)
        return Content(date: dateFormat.string(from: day.date), resort: resort, runs: day.runs.count,
                       distance: String(km.dropLast(2)), sessions: sessions)
    }

    /// 영업일(06:00 시작)의 자정을 넘긴 시각에는 "다음 날"을 붙인다. 시작부터 넘겼으면 앞에 한 번만
    static func span(_ a: Date, _ b: Date, day: Date) -> String {
        let midnight = day.addingTimeInterval(18 * 3600)
        if a >= midnight { return "다음 날 \(RecordFormat.time(a))~\(RecordFormat.time(b))" }
        return "\(RecordFormat.time(a))~\(b >= midnight ? "다음 날 " : "")\(RecordFormat.time(b))"
    }

    /// 1080×1350. 공유 이미지는 받는 사람 화면 설정과 관계없이 밝은 한 가지
    @MainActor static func render(_ c: Content) -> UIImage? {
        let r = ImageRenderer(content: ShareImageView(c: c).environment(\.colorScheme, .light).dynamicTypeSize(.large))
        r.scale = 2
        return r.uiImage
    }

    @MainActor static func share(_ day: Stats.Day) {
        let c = content(day, resort: Resort.name(day.resortId)) { RecordFormat.session($0, resortId: day.resortId) }
        guard let image = render(c) else { return }
        ShareSheet.present([image])
    }
}

/// 540×675pt(2배로 1080×1350). 글자 크기는 이미지 안에서 고정이라 Dynamic Type을 따르지 않는다
private struct ShareImageView: View {
    let c: ShareImage.Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(c.date).font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.secondaryText)
            Text(c.resort).font(.system(size: 44, weight: .bold)).padding(.top, 6)
            HStack(alignment: .lastTextBaseline, spacing: 28) { // 하강·거리 라벨 줄을 맞춘다
                stat(Text("\(c.runs)").font(.system(size: 120, weight: .heavy)).tracking(-2) + Text("회").font(.system(size: 48, weight: .heavy)),
                     "하강", color: .accentText)
                stat(Text(c.distance).font(.system(size: 56, weight: .bold)) + Text("km").font(.system(size: 28, weight: .bold)),
                     "거리", color: .primaryText)
            }
            .padding(.top, 44)
            Spacer(minLength: 16)
            if !c.sessions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(c.sessions.enumerated()), id: \.offset) { i, s in
                        if i > 0 { Rectangle().fill(Color(light: 0xE3ECEF, dark: 0x23404B)).frame(height: 1) }
                        HStack {
                            Text(s.name).fontWeight(.semibold)
                                + (s.time.map { Text(" \($0)").foregroundStyle(Color.secondaryText) } ?? Text(""))
                            Spacer(minLength: 12)
                            Text("\(s.runs)회").fontWeight(.bold)
                        }
                        .font(.system(size: 22)).monospacedDigit()
                        .padding(.horizontal, 24).padding(.vertical, c.sessions.count > 2 ? 15 : 20)
                    }
                }
                .background(Color.card, in: RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.cardBorder))
            }
            Text("SlopeMate").font(.system(size: 18, weight: .bold)).foregroundStyle(Color.accentText).padding(.top, 24)
        }
        .foregroundStyle(Color.primaryText)
        .lineLimit(1).minimumScaleFactor(0.6)
        .padding(EdgeInsets(top: 48, leading: 44, bottom: 40, trailing: 44))
        .frame(width: 540, height: 675, alignment: .topLeading)
        .background(LinearGradient(stops: [.init(color: Color(light: 0xCFE8F0, dark: 0xCFE8F0), location: 0), .init(color: .bg, location: 0.58)],
                                   startPoint: .top, endPoint: .bottom))
    }

    private func stat(_ value: Text, _ label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            value.foregroundStyle(color).monospacedDigit()
            Text(label).font(.system(size: 20)).foregroundStyle(Color.secondaryText)
        }
    }
}

#Preview("공유 이미지 · 세션 네 가지") {
    ShareImageView(c: .init(date: "2026년 12월 6일 일요일", resort: "하이원", runs: 8, distance: "9.6", sessions: [
        .init(name: "주간", time: "09:40~16:20", runs: 3), .init(name: "야간", time: "18:30~21:10", runs: 2),
        .init(name: "심야", time: "22:40~다음 날 01:30", runs: 2), .init(name: "미분류", time: nil, runs: 1)]))
}
