import Foundation
import GRDB
import Testing
@testable import SlopeMate

struct RecordQueriesTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var path: String { dir.appending(path: "t.sqlite").path }

    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    /// 기록 하나에 딸린 행을 모두 만든다
    func fill(_ db: AppDatabase, _ resort: String, at t0: Date) throws -> Recording {
        let rec = try db.createRecording(resortId: resort, at: t0)
        var p = Point(recordingId: rec.id, t: t0 + 10, lat: 37, lon: 128, hAcc: 5, gpsAlt: 0, vAcc: 5, speed: 0, seq: 0)
        try db.insert(&p)
        _ = try db.restart(rec, reason: "system", at: t0 + 60)
        try db.addVehicle(rec, DateInterval(start: t0 + 100, duration: 60))
        try db.end(rec, at: t0 + 3600, reason: "user")
        try db.queue.write { d in
            try LiftWait(recordingId: rec.id, boardAt: t0 + 20, resortId: resort, liftId: "l", waitSec: 30, sendState: "pending").insert(d)
            try SnowRating(recordingId: rec.id, runStart: t0 + 30, runEnd: t0 + 90, resortId: resort, slopeId: "s",
                           value: .ok, ratedAt: t0 + 100, sendState: "dropped").insert(d)
        }
        try db.refreshCache(rec, map: nil)
        return rec
    }

    func count(_ db: AppDatabase, _ table: String) throws -> Int {
        try db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
    }

    /// 그 영업일 그 리조트의 기록(두 번 나눠 기록한 것 포함)과 딸린 행만 지운다. 다른 날·다른 리조트·진행 중 기록은 남는다.
    @Test func deleteDayRemovesOnlyThatDay() throws {
        let db = try AppDatabase(path: path)
        let f = ISO8601DateFormatter()
        let morning = f.date(from: "2026-12-19T09:00:00+09:00")!
        _ = try fill(db, "high1", at: morning)
        _ = try fill(db, "high1", at: morning + 4 * 3600)                                // 같은 날 두 번째 기록
        let other = try fill(db, "konjiam", at: morning)                                 // 같은 날 다른 리조트
        let nextDay = try fill(db, "high1", at: f.date(from: "2026-12-20T09:00:00+09:00")!)
        let open = try db.createRecording(resortId: "high1", at: morning + 8 * 3600)     // 진행 중

        let day = Stats.Day(date: BusinessDay.start(of: morning), resortId: "high1", runs: [], usedGPSAltitude: false)
        #expect(try db.recordings(of: day).count == 2)
        try db.delete(day)

        #expect(try db.recordings(of: day).isEmpty)
        let left = try db.queue.read { try UUID.fetchSet($0, sql: "SELECT id FROM recording") }
        #expect(left == [other.id, nextDay.id, open.id])
        for t in ["point", "restart", "gap", "vehicle", "lift_wait", "snow_rating", "recording_cache"] {
            let orphans = try db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(t) WHERE recordingId NOT IN (SELECT id FROM recording)")! }
            #expect(orphans == 0, "\(t)")
        }
        #expect(try count(db, "point") == 2)
        #expect(try count(db, "recording_cache") == 2)
    }

    /// 여러 번 기록한 날은 껐다 켠 사이를 뺀 합계와 첫 시작~마지막 종료를 따로 보여 준다
    @Test func recordedTime() {
        let t0 = ISO8601DateFormatter().date(from: "2026-12-05T22:28:00+09:00")!
        func span(_ from: Double, _ to: Double) -> DateInterval { DateInterval(start: t0 + from * 60, end: t0 + to * 60) }
        #expect(RecordFormat.recorded([]) == nil)
        let one = RecordFormat.recorded([span(0, 87)])
        #expect(one?.line == "22:28~23:55 기록" && one?.range == nil)
        let two = RecordFormat.recorded([span(0, 5), span(77, 87)])
        #expect(two?.line == "기록 2회 · 총 15분" && two?.range == "22:28~23:55")
        #expect(RecordFormat.duration(20) == "1분")
        #expect(RecordFormat.duration(3600) == "1시간")
        #expect(RecordFormat.duration(80 * 60) == "1시간 20분")
    }

    @Test func josa() {
        #expect(RecordFormat.josa("하이원", "은", "는") == "은")
        #expect(RecordFormat.josa("곤지암 리조트", "은", "는") == "는")
        #expect(RecordFormat.josa("하이원 시즌권", "을", "를") == "을")
        #expect(RecordFormat.josa("Pass", "을", "를") == "을")
    }
}
