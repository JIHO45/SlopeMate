import ActivityKit
import Foundation

/// Live Activity를 띄우고 갱신하고 끝낸다 (R23, 04-flows Live Activity). 버튼은 없다.
/// 사용자가 Live Activity를 꺼 두거나 시작에 실패해도 기록은 그대로 계속된다.
@MainActor final class LiveRecording {
    typealias Attributes = RecordingActivityAttributes
    typealias State = Attributes.ContentState
    private var activity: Activity<Attributes>?
    private var last: State?
    private var lastPush = Date.distantPast

    /// 기록 중 상태를 보여준다.
    /// - 같은 기록의 카드가 있으면 상태만 바꾼다(백그라운드에서도 된다).
    /// - `renew`(앱이 앞으로 왔을 때): 카드가 없거나 8시간이 다 돼 가면 새로 띄우고, 성공한 뒤에만 옛 카드를 끝낸다.
    func show(recordingId: UUID, resortName: String, _ state: State, renew: Bool = false, now: Date = .now) {
        let id = recordingId.uuidString
        if activity?.attributes.recordingId != id || activity?.activityState != .active {
            activity = Activity<Attributes>.activities.first { $0.attributes.recordingId == id && $0.activityState == .active }
        }
        // 다른 기록의 카드는 남기지 않는다
        for a in Activity<Attributes>.activities where a.attributes.recordingId != id {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        let old = activity
        let aging = old.map { now.timeIntervalSince($0.attributes.shownAt) >= Attributes.maxAge - 1800 } ?? true
        guard (old == nil || (renew && aging)), ActivityAuthorizationInfo().areActivitiesEnabled,
              let new = try? Activity.request(attributes: Attributes(recordingId: id, resortName: resortName, shownAt: now),
                                              content: ActivityContent(state: state, staleDate: now + Attributes.maxAge))
        else {
            // 새로 띄우지 않거나 못 띄웠으면(백그라운드 등) 있는 카드의 상태만 바꾼다
            return update(state, force: true, now: now)
        }
        activity = new
        last = state
        lastPush = now
        // 새 카드 말고는 모두 끝낸다: 옛 카드와 8시간이 지나 끝난(stale) 카드도(못 찾아 old가 nil이어도 남지 않게)
        for a in Activity<Attributes>.activities where a.id != new.id {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// 하강 수·멈춤이 바뀌면 바로, 거리만 바뀌면 30초에 한 번 소리 없이 갱신한다.
    func update(_ state: State, force: Bool = false, now: Date = .now) {
        guard let activity, state != last else { return }
        let urgent = force || state.runs != last?.runs || state.stopped != last?.stopped
        guard urgent || now.timeIntervalSince(lastPush) >= 30 else { return }
        last = state
        lastPush = now
        let content = ActivityContent(state: state, staleDate: activity.attributes.shownAt + Attributes.maxAge)
        Task { await activity.update(content) }
    }

    /// 이 기록의 카드가 떠 있는지 (복구 화면에서 끝낼 때 합계를 계산할지 정한다)
    func hasCard(_ recordingId: UUID) -> Bool {
        Activity<Attributes>.activities.contains { $0.attributes.recordingId == recordingId.uuidString }
    }

    /// 기록 종료: 그 기록의 카드를 찾아 하루 합계를 잠깐(지금부터 5분) 보여주고 끝낸다. 상태가 없으면 바로 끝낸다.
    /// `endedAt`은 저장된 종료 시각(06:00 자동 종료는 마지막 위치 시각)이고, 카드의 경과 시간을 이 값으로 고정한다.
    func end(recordingId: UUID, _ state: State?, endedAt: Date, now: Date = .now) {
        let id = recordingId.uuidString
        if activity?.attributes.recordingId == id {
            activity = nil
            last = nil
        }
        var final = state
        final?.ended = true
        final?.endedAt = endedAt
        for a in Activity<Attributes>.activities where a.attributes.recordingId == id {
            Task {
                if let final {
                    await a.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(now + 5 * 60))
                } else {
                    await a.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }
}
