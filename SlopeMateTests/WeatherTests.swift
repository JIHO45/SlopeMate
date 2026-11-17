import Foundation
import Testing
@testable import SlopeMate

@MainActor
struct WeatherTests {
    let f = ISO8601DateFormatter()
    func at(_ s: String) -> Date { f.date(from: s + "+09:00")! }

    func snapshot(_ t: Date, hours: [WeatherSnapshot.Hour] = []) -> WeatherSnapshot {
        let u = URL(string: "https://example.com")!
        return WeatherSnapshot(fetchedAt: t,
                               current: .init(temperature: -3, symbolName: "snow", condition: "눈", windSpeed: 2, humidity: 0.7),
                               hours: hours, days: [], attribution: .init(markLightURL: u, markDarkURL: u, legalPageURL: u))
    }

    @Test func hourlyRange() {
        let r = Weather.hourlyRange(now: at("2026-12-10T10:00:00"))
        #expect(r.start == at("2026-12-09T12:00:00"))
        #expect(r.end == at("2026-12-11T10:00:00"))
        // 새벽 2시는 전날 영업일
        let n = Weather.hourlyRange(now: at("2026-12-11T02:00:00"))
        #expect(n.start == at("2026-12-09T12:00:00"))
        #expect(n.end == at("2026-12-12T02:00:00"))
    }

    @Test func next24h() {
        let start = at("2026-12-09T12:00:00")
        let hours = (0..<48).map { i in
            WeatherSnapshot.Hour(date: start.addingTimeInterval(Double(i) * 3600), temperature: 0, symbolName: "sun.max",
                                 precipitationChance: 0, windSpeed: 0, humidity: 0.5, snowfall: nil)
        }
        let next = snapshot(start, hours: hours).next24h(now: at("2026-12-10T10:30:00"))
        #expect(next.count == 24)
        #expect(next.first?.date == at("2026-12-10T10:00:00"))  // 지금 시간대부터
    }

    final class Fake {
        var now: Date
        var calls: [String] = []
        var fail = false
        init(_ now: Date) { self.now = now }
    }
    struct Failed: Error {}

    func cache(_ fake: Fake) -> WeatherCache {
        WeatherCache(fetch: { resort, t in
            fake.calls.append(resort.id)
            if fake.fail { throw Failed() }
            return self.snapshot(t)
        }, now: { fake.now })
    }

    @Test func refetchAfter30Minutes() async throws {
        let fake = Fake(at("2026-12-10T10:00:00"))
        let c = cache(fake)
        let a = Resort.all[0], b = Resort.all[1]
        _ = try await c.weather(for: a)
        fake.now = at("2026-12-10T10:29:00")
        #expect(try await c.weather(for: a).fetchedAt == at("2026-12-10T10:00:00"))
        _ = try await c.weather(for: b)  // 리조트별 캐시
        #expect(fake.calls == [a.id, b.id])
        fake.now = at("2026-12-10T10:30:00")
        #expect(try await c.weather(for: a).fetchedAt == at("2026-12-10T10:30:00"))
        #expect(fake.calls == [a.id, b.id, a.id])
    }

    @Test func failureUsesCacheOrThrows() async throws {
        let fake = Fake(at("2026-12-10T10:00:00"))
        let c = cache(fake)
        let a = Resort.all[0]
        fake.fail = true
        await #expect(throws: Failed.self) { try await c.weather(for: a) }  // 캐시 없음

        fake.fail = false
        _ = try await c.weather(for: a)
        fake.fail = true
        fake.now = at("2026-12-10T10:20:00")
        #expect(try await c.weather(for: a).fetchedAt == at("2026-12-10T10:00:00"))  // 30분 안: 캐시
        fake.now = at("2026-12-10T10:31:00")
        #expect(try await c.weather(for: a).fetchedAt == at("2026-12-10T10:00:00"))  // 조회 실패: 낡은 캐시라도
        #expect(fake.calls == [a.id, a.id, a.id])  // 30분이 지났으니 다시 조회는 했다
        fake.now = at("2026-12-10T13:01:00")
        await #expect(throws: Failed.self) { try await c.weather(for: a) }  // 3시간 넘은 캐시는 쓰지 않음
    }
}
