import ActivityKit
import Foundation

/// Live Activity 기록 상태 (R23). 앱과 위젯 확장이 함께 쓴다(위젯 타깃에도 포함).
nonisolated struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 이번 기록 시작 시각 (경과 시간은 위젯이 이 값으로 센다)
        var startedAt: Date
        /// 오늘 하루 합계
        var runs: Int
        var distance: Double
        /// 기록이 멈춘 이유(권한 꺼짐, 저장 실패). 기록 중이면 nil
        var stopped: String?
        /// 기록을 끝냄: 하루 합계를 잠깐 보여준다
        var ended = false
        /// 끝낸 시각. 경과 시간을 이 값으로 고정한다
        var endedAt: Date?
    }

    /// 이 카드가 보여주는 기록. 끝낸 기록의 카드를 찾고, 다른 기록의 카드를 이어 쓰지 않는 데 쓴다.
    var recordingId: String
    var resortName: String
    /// 이 카드를 띄운 시각. 8시간이 지나면 갱신이 끝나므로 "앱을 열면 다시 표시"로 바뀐다.
    var shownAt: Date

    static let maxAge: TimeInterval = 8 * 3600
    /// 누르면 기록 중 화면(S5)
    static let url = URL(string: "slopemate://recording")!
}
