import Foundation
import Testing
@testable import SlopeMate

struct ForgottenStopTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func rec() -> Recording { Recording(id: UUID(), resortId: "high1", startedAt: t0) }
    func run(_ start: TimeInterval, _ end: TimeInterval) -> RunDetector.Run {
        RunDetector.Run(start: t0 + start, end: t0 + end, distance: 1000, drop: 300, maxSpeed: 10, avgSpeed: 8, movingTime: 120)
    }

    @Test func idleDeadlineUsesLastRunEnd() {
        #expect(ForgottenStop.idleDeadline(rec(), RunDetector.Summary()) == t0 + 3600)
        // 하강이 길어지면(종료 시각만 늘어남) 기한도 늦어진다
        let s = RunDetector.Summary(runs: [run(600, 700), run(1200, 1900)])
        #expect(ForgottenStop.idleDeadline(rec(), s) == t0 + 1900 + 3600)
    }

    @Test func farAlertNeedsRunStartedAfterSending() {
        let sent = t0 + 1000
        #expect(ForgottenStop.farAlertAllowed(sentAt: nil, RunDetector.Summary()))
        // 보내기 전에 시작해 그 뒤로 길어진 하강은 새 하강이 아니다
        #expect(!ForgottenStop.farAlertAllowed(sentAt: sent, RunDetector.Summary(runs: [run(900, 1500)])))
        #expect(ForgottenStop.farAlertAllowed(sentAt: sent, RunDetector.Summary(runs: [run(900, 950), run(1100, 1200)])))
    }

    @Test func farDistance() {
        let high1 = Resort.all.first { $0.id == "high1" }!
        #expect(!ForgottenStop.isFar(lat: high1.latitude + 0.02, lon: high1.longitude, from: high1)) // 약 2.2km
        #expect(ForgottenStop.isFar(lat: high1.latitude + 0.05, lon: high1.longitude, from: high1))  // 약 5.6km
    }

    @Test func vehicleIntervalsFromActivities() {
        let acts: [(start: Date, automotive: Bool)] = [
            (t0, false), (t0 + 100, true), (t0 + 200, true), (t0 + 300, false), (t0 + 500, true),
        ]
        let iv = ForgottenStop.vehicleIntervals(acts, end: t0 + 600)
        #expect(iv == [DateInterval(start: t0 + 100, end: t0 + 300), DateInterval(start: t0 + 500, end: t0 + 600)])
        #expect(ForgottenStop.vehicleIntervals([], end: t0).isEmpty)
    }

    @Test func idleActionWhenDeadlineMovesIntoPast() {
        let now = t0 + 10_000
        // 차로 내려온 길을 하강으로 봐서 미래(아직 안 울림)로 예약했는데, 차량 재판정으로 과거로 당겨짐 → 지금 보냄
        #expect(ForgottenStop.idleAction(previous: now + 600, new: now - 600, now: now) == .sendNow)
        // 앞선 기한도 이미 지나 울렸음 → 같은 무하강을 다시 알리지 않음
        #expect(ForgottenStop.idleAction(previous: now - 60, new: now - 600, now: now) == .cancel)
        // 예약한 적이 없음 → 지금 보냄
        #expect(ForgottenStop.idleAction(previous: nil, new: now - 600, now: now) == .sendNow)
        // 지금 보낸 뒤 같은 기한 → 그대로
        #expect(ForgottenStop.idleAction(previous: now - 600, new: now - 600, now: now) == .keep)
        // 새 하강으로 미래 기한 → 예약
        #expect(ForgottenStop.idleAction(previous: now - 600, new: now + 3000, now: now) == .schedule(now + 3000))
    }

    @Test func farCheckIgnoresInaccuratePoint() {
        let id = UUID()
        func p(_ dt: TimeInterval, _ lat: Double, hAcc: Double) -> Point {
            Point(recordingId: id, t: t0 + dt, lat: lat, lon: 128.84, hAcc: hAcc, gpsAlt: 0, vAcc: 5, speed: 0, seq: 0)
        }
        let pts = [p(0, 37.2067, hAcc: 5), p(2, 37.2068, hAcc: 5), p(4, 37.30, hAcc: 500)] // 마지막 점은 정확도 500m
        #expect(ForgottenStop.latestReliable(pts)?.lat == 37.2068)
        let jump = [p(0, 37.2067, hAcc: 5), p(2, 37.30, hAcc: 5)] // 2초에 10km: 튐
        #expect(ForgottenStop.latestReliable(jump)?.lat == 37.2067)
    }
}
