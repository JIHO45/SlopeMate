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
