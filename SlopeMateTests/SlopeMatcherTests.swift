import Foundation
import Testing
@testable import SlopeMate

struct SlopeMatcherTests {
    // 위도 37°, 경도 128° 근처에서 미터를 도로 바꾼다
    static let lat0 = 37.0, lon0 = 128.0
    static func ll(east: Double, north: Double) -> [Double] {
        [lat0 + north / 110_540, lon0 + east / (cos(lat0 * .pi / 180) * 111_320)]
    }

    static func point(east: Double, north: Double) -> Point {
        let c = ll(east: east, north: north)
        return Point(recordingId: UUID(), t: Date(), lat: c[0], lon: c[1], hAcc: 5, gpsAlt: 0, vAcc: 5, speed: 0, seq: 0)
    }

    /// 남북 방향 점들 (east 고정, north from…to)
    static func points(east: Double, north: ClosedRange<Double>, count: Int = 20) -> [Point] {
        (0..<count).map { i in
            point(east: east, north: north.lowerBound + (north.upperBound - north.lowerBound) * Double(i) / Double(count - 1))
        }
    }

    static func map(_ slopes: [(id: String, lines: [[[Double]]], area: Bool)]) throws -> SlopeMap {
        let json: [String: Any] = [
            "resort_id": "test", "source": "test", "osm_timestamp": "",
            "slopes": slopes.map { ["id": $0.id, "osm_ids": [], "lines": $0.lines, "area": $0.area] },
            "lifts": [],
        ]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SlopeMap.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// east 위치의 남북 직선 슬로프
    static func line(_ id: String, east: Double, north: ClosedRange<Double> = 0...500) -> (id: String, lines: [[[Double]]], area: Bool) {
        (id, [[ll(east: east, north: north.lowerBound), ll(east: east, north: north.upperBound)]], false)
    }

    @Test func pointsAlongLine() throws {
        let m = try Self.map([Self.line("a", east: 0), Self.line("b", east: 200)])
        #expect(SlopeMatcher.match(Self.points(east: 5, north: 0...500), map: m) == "a")
    }

    @Test func farAwayIsNil() throws {
        let m = try Self.map([Self.line("a", east: 0)])
        #expect(SlopeMatcher.match(Self.points(east: 100, north: 0...500), map: m) == nil)
    }

    @Test func splitBetweenParallelIsNil() throws {
        let m = try Self.map([Self.line("a", east: 0), Self.line("b", east: 40)])
        let pts = Self.points(east: 0, north: 0...250, count: 10) + Self.points(east: 40, north: 250...500, count: 10)
        #expect(SlopeMatcher.match(pts, map: m) == nil)
    }

    @Test func insideArea() throws {
        let ring = [Self.ll(east: 0, north: 0), Self.ll(east: 200, north: 0), Self.ll(east: 200, north: 400),
                    Self.ll(east: 0, north: 400), Self.ll(east: 0, north: 0)]
        let m = try Self.map([("area", [ring], true), Self.line("b", east: 300)])
        #expect(SlopeMatcher.match(Self.points(east: 100, north: 50...350), map: m) == "area")
    }

    @Test func overlapPicksLarger() throws {
        // b는 a의 앞 30%만 겹침
        let m = try Self.map([Self.line("a", east: 0), Self.line("b", east: 10, north: 0...150)])
        #expect(SlopeMatcher.match(Self.points(east: 0, north: 0...500), map: m) == "a")
    }

    @Test func emptyIsNil() throws {
        let m = try Self.map([Self.line("a", east: 0)])
        #expect(SlopeMatcher.match([], map: m) == nil)
    }

    @Test func bundledMapMatchesOwnLine() throws {
        let map = try #require(SlopeMap.load(resortId: "high1"))
        let slope = try #require(map.slopes.first { $0.area != true && $0.lines[0].count >= 5 })
        let pts = slope.lines[0].map {
            Point(recordingId: UUID(), t: Date(), lat: $0[0], lon: $0[1], hAcc: 5, gpsAlt: 0, vAcc: 5, speed: 0, seq: 0)
        }
        #expect(SlopeMatcher.match(pts, map: map) == slope.id)
    }
}
