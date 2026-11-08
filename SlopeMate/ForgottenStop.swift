import CoreMotion
import Foundation
import UserNotifications

/// 종료를 잊은 기록 대응 (R49, 05-design 3장).
nonisolated enum ForgottenStop {
    /// 마지막 하강(없으면 기록 시작) 뒤 이 시간 동안 하강이 없으면 알림
    static let idleLimit: TimeInterval = 60 * 60
    /// 기록에 고른 리조트에서 이만큼 벗어나면 알림(m)
    static let farDistance = 5000.0

    // MARK: 판단 (순수 함수)

    /// 60분 알림 시각: 차량 구간을 뺀 판정의 마지막 하강 종료 시각 기준
    static func idleDeadline(_ rec: Recording, _ summary: RunDetector.Summary) -> Date {
        (summary.runs.last?.end ?? rec.startedAt).addingTimeInterval(idleLimit)
    }

    /// 5km 알림을 보낸 뒤에 **시작한** 하강이 있어야 다시 보낸다. 하강이 길어지거나 차량 재판정으로 줄어든 것은 새 하강이 아니다.
    static func farAlertAllowed(sentAt: Date?, _ summary: RunDetector.Summary) -> Bool {
        guard let sentAt else { return true }
        return summary.runs.contains { $0.start > sentAt }
    }

    enum IdleAction: Equatable { case keep, schedule(Date), sendNow, cancel }

    /// 60분 알림 기한이 바뀌었을 때 할 일. previous는 이 기록에서 마지막으로 정한 기한.
    /// 차량 재판정으로 기한이 과거로 당겨지면: 앞선 예약이 아직 울리지 않았으면(또는 예약이 없었으면) 지금 보내고,
    /// 이미 울렸으면 같은 무하강 구간을 다시 알리지 않는다.
    static func idleAction(previous: Date?, new: Date, now: Date) -> IdleAction {
        if previous == new { return .keep }
        if new > now { return .schedule(new) }
        if let previous, previous <= now { return .cancel }
        return .sendNow
    }

    /// 이탈 판단에 쓸 점: 판정과 같은 기준(정확도·튐)을 통과한 가장 최근 점
    static func latestReliable(_ points: [Point]) -> Point? {
        RunDetector.clean(Array(points.suffix(30)), RunDetector.Params()).last
    }

    static func isFar(lat: Double, lon: Double, from resort: Resort) -> Bool {
        let a = Point(recordingId: UUID(), t: .now, lat: lat, lon: lon, hAcc: 0, gpsAlt: 0, vAcc: 0, speed: 0, seq: 0)
        let b = Point(recordingId: UUID(), t: .now, lat: resort.latitude, lon: resort.longitude, hAcc: 0, gpsAlt: 0, vAcc: 0, speed: 0, seq: 0)
        return RunDetector.distance(a, b) >= farDistance
    }

    /// 활동 기록 → 차량 구간. 활동은 다음 활동이 시작할 때까지 이어진다고 본다. 마지막 활동은 `end`까지.
    static func vehicleIntervals(_ activities: [(start: Date, automotive: Bool)], end: Date) -> [DateInterval] {
        let sorted = activities.sorted { $0.start < $1.start }
        var out: [DateInterval] = []
        for (i, a) in sorted.enumerated() where a.automotive {
            let to = i + 1 < sorted.count ? sorted[i + 1].start : end
            guard to > a.start else { continue }
            if let last = out.last, last.end >= a.start {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, to))
            } else {
                out.append(DateInterval(start: a.start, end: to))
            }
        }
        return out
    }

    // MARK: 기기

    /// 기록 구간의 차량 구간. 동작 권한이 없거나 조회에 실패하면 nil(기존 값을 지우지 않는다).
    static func queryVehicle(from: Date, to: Date) async -> [DateInterval]? {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized else { return nil }
        return await withCheckedContinuation { cont in
            CMMotionActivityManager().queryActivityStarting(from: from, to: to, to: OperationQueue()) { acts, error in
                guard let acts, error == nil else { return cont.resume(returning: nil) }
                // 신뢰도 낮음은 차량으로 보지 않는다
                let list = acts.map { (start: $0.startDate, automotive: $0.automotive && $0.confidence != .low) }
                cont.resume(returning: vehicleIntervals(list, end: to))
            }
        }
    }

    static let idleID = "forgottenStop.idle"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 기존 예약을 지우고, 기한이 미래면 예약, nil이면 지우기만 한다. sendNow면 바로 보낸다.
    static func scheduleIdle(at deadline: Date?, now: Date = .now, sendNow: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [idleID])
        let body = content("한 시간 넘게 하강이 없어요. 스키장을 떠났다면 기록을 끝내 주세요.")
        if sendNow { return center.add(UNNotificationRequest(identifier: idleID + ".now", content: body, trigger: nil)) }
        guard let deadline, deadline > now else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: deadline.timeIntervalSince(now), repeats: false)
        center.add(UNNotificationRequest(identifier: idleID, content: body, trigger: trigger))
    }

    static func sendFar() {
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "forgottenStop.far", content: content("리조트에서 멀어졌어요. 스키장을 떠났다면 기록을 끝내 주세요."), trigger: nil))
    }

    private static func content(_ body: String) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = "아직 기록 중이에요"
        c.body = body
        c.sound = .default
        return c
    }

    // 60분 알림 기한, 기록별 (앱이 다시 실행돼도 중복 발송하지 않게)
    static func idleDeadline(_ rec: Recording) -> Date? { UserDefaults.standard.object(forKey: "idleDeadline-\(rec.id)") as? Date }
    static func setIdleDeadline(_ rec: Recording, _ at: Date?) { UserDefaults.standard.set(at, forKey: "idleDeadline-\(rec.id)") }

    // 5km 알림을 보낸 시각, 기록별
    static func farSentAt(_ rec: Recording) -> Date? { UserDefaults.standard.object(forKey: "farSent-\(rec.id)") as? Date }
    static func setFarSent(_ rec: Recording, _ at: Date?) { UserDefaults.standard.set(at, forKey: "farSent-\(rec.id)") }
}
