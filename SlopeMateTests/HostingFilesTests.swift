import Foundation
import Testing
@testable import SlopeMate

/// Hosting에 올리는 파일(hosting/public)이 앱에서 읽히는지. 올리기 전에 돌린다.
struct HostingFilesTests {
    static let dir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "hosting/public")

    @Test func configDecodes() throws {
        let c = try JSONDecoder().decode(ServerConfig.Config.self, from: Data(contentsOf: Self.dir.appending(path: "config.json")))
        let ids = Set(Resort.all.map(\.id))
        #expect(c.slopeNames.allSatisfy(ids.contains), "없는 리조트 ID")
    }

    @Test func timetablesDecode() throws {
        let list = try Timetable.decode(Data(contentsOf: Self.dir.appending(path: "timetables.json")))
        let ids = Set(Resort.all.map(\.id))
        #expect(list.allSatisfy { ids.contains($0.resortId) && $0.validFrom <= $0.validTo })
    }

    @Test func slopeNamesFollowServer() throws {
        let d = UserDefaults.standard
        let saved = (d.dictionary(forKey: "slopeNamesShown"), d.data(forKey: "serverConfig"))
        defer { d.set(saved.0, forKey: "slopeNamesShown"); d.set(saved.1, forKey: "serverConfig") }
        let on = ServerConfig.Config(slopeNames: ["high1"], crewSync: true, samples: true)
        ServerConfig.apply(on, data: try JSONEncoder().encode(on))
        #expect(SlopeNames.isShown("high1"))
        #expect(!SlopeNames.isShown("vivaldi"))
        // 목록에서 빠지면 꺼진다
        let off = ServerConfig.Config(slopeNames: [], crewSync: true, samples: true)
        ServerConfig.apply(off, data: try JSONEncoder().encode(off))
        #expect(!SlopeNames.isShown("high1"))
    }

    /// 다음 조회: 받으면 1시간 뒤, 못 받으면 5분 뒤. 기다릴 시간은 그 시각까지 남은 만큼(앱을 다시 열어도 밀리거나 당겨지지 않음).
    @Test func refreshSchedule() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let ok = ServerConfig.next(after: t, ok: true)
        #expect(ServerConfig.secondsUntilRefresh(next: ok, now: t.addingTimeInterval(50 * 60)) == 10 * 60)
        #expect(ServerConfig.secondsUntilRefresh(next: ok, now: t.addingTimeInterval(59 * 60)) == 60)
        #expect(ServerConfig.secondsUntilRefresh(next: ok, now: t.addingTimeInterval(2 * 3600)) == 0)
        // 실패 뒤 1분 만에 다시 열어도 바로 요청하지 않는다
        let failed = ServerConfig.next(after: t, ok: false)
        #expect(ServerConfig.secondsUntilRefresh(next: failed, now: t.addingTimeInterval(60)) == 240)
        // 처음에는 바로
        #expect(ServerConfig.secondsUntilRefresh(next: nil, now: t) == 0)
    }
}
