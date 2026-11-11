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
        // 우리 호스트의 /i/{토큰}만: 끝의 / 하나는 허용, 다른 경로·호스트·http·추가 경로는 거부
        #expect(Crews.token(from: "https://slopemate-f9a5b.web.app/i/\(t)/") == t)
        #expect(Crews.token(from: "https://slopemate-f9a5b.web.app/i/\(t)?utm=x") == t)
        #expect(Crews.token(from: "https://slopemate-f9a5b.web.app/support/\(t)") == nil)
        #expect(Crews.token(from: "https://slopemate-f9a5b.web.app/i/\(t)/more") == nil)
        #expect(Crews.token(from: "https://evil.example.com/i/\(t)") == nil)
        #expect(Crews.token(from: "http://slopemate-f9a5b.web.app/i/\(t)") == nil)
        #expect(Crews.token(from: "https://slopemate-f9a5b.web.app/x/i/\(t)") == nil)
    }

    /// 가입 전 이름 신고 메일: 초대 링크·당시 이름이 본문에 들어가고, 이름의 &·= 같은 글자가 주소를 깨지 않는다
    @Test func reportMailHasLinkAndNames() throws {
        let t = "AbCdEfGhIjKlMnOpQr_-12"
        let url = try #require(Crews.reportMail(to: "a@b.c", token: t, crewName: "주말&반=1", ownerName: "지호"))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items.keys.sorted() == ["body", "subject"])
        #expect(items["subject"] == "크루 이름 신고: 주말&반=1")
        #expect(items["body"]?.contains(Crews.inviteURL(t).absoluteString) == true)
        #expect(items["body"]?.contains("크루장 이름: 지호") == true)
    }

    /// 같은 초대 링크를 다시 눌러도(앞의 초대를 비운 뒤든 아니든) 받을 때마다 알린다
    @Test func sameInviteAgain() {
        let crews = Crews()
        crews.receiveInvite("AbCdEfGhIjKlMnOpQr_-12")
        let first = crews.inviteRequests
        crews.receiveInvite("AbCdEfGhIjKlMnOpQr_-12")
        #expect(crews.inviteRequests == first + 1)
        #expect(crews.pendingInvite == "AbCdEfGhIjKlMnOpQr_-12")
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
