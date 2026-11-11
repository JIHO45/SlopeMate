import FirebaseFunctions
import Foundation
import Testing
@testable import SlopeMate

struct CrewsTests {
    @Test func inviteToken() {
        let t = "AbCdEfGhIjKlMnOpQr_-12"
        #expect(Crews.token(from: Crews.inviteURL(t).absoluteString) == t)
        #expect(Crews.token(from: "  \(t)\n") == t)
        #expect(Crews.token(from: "https://slopemate-f9a5b.web.app/i/short") == nil)
        #expect(Crews.token(from: "아무 글") == nil)
    }
}

/// 크루로 보내는 합계 (R15, R17): 이번 시즌 합계와 리조트별 방문일만, 거리는 km 소수 한 자리
struct SummaryPayloadTests {
    @Test func emptyAndOneDay() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try AppDatabase(path: dir.appending(path: "t.sqlite").path)
        let empty = try SummarySync.payload(db)
        #expect(empty == .init(season: HomeData.currentSeason(), visitDays: 0, runs: 0, distanceKm: 0, resortDays: [:]))

        var tr = Track()
        let rec = try db.createRecording(resortId: "high1", at: tr.t)
        for _ in 0..<3 { tr.lap() }
        for var p in tr.pts { p.recordingId = rec.id; try db.insert(&p) }
        let p = try SummarySync.payload(db, now: tr.t)
        #expect(p.season == HomeData.currentSeason(now: tr.t))
        #expect(p.visitDays == 1 && p.runs > 0 && p.distanceKm > 0)
        #expect(p.resortDays == ["high1": 1])
        #expect(p.distanceKm == (p.distanceKm * 10).rounded() / 10)
    }
}

/// 신고·금지어 (R16): 앱 쪽 판단
struct ReportTests {
    @Test func noticeOncePerReport() {
        // 처리된 신고만, 본 것은 빼고, 조치가 하나라도 있으면 "조치했어요"
        let n = Crews.notice(statuses: ["a": "resolved", "b": "dismissed", "c": "open"], seen: [])
        #expect(n?.text == "신고한 이름을 확인해 조치했어요.")
        #expect(Set(n?.ids ?? []) == ["a", "b"])
        #expect(Crews.notice(statuses: ["b": "dismissed"], seen: [])?.text == "신고한 이름을 검토했어요.")
        #expect(Crews.notice(statuses: ["a": "resolved", "c": "open"], seen: ["a"]) == nil)
    }

    @Test func bannedNameIsItsOwnError() {
        let banned = NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.invalidArgument.rawValue,
                             userInfo: [NSLocalizedDescriptionKey: "banned"])
        let format = NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.invalidArgument.rawValue,
                             userInfo: [NSLocalizedDescriptionKey: "name"])
        #expect(Account.isBannedName(banned))
        #expect(!Account.isBannedName(format))
        #expect(Account.isRefusal(format))
    }
}
