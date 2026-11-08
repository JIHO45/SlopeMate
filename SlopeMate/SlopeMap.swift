import Foundation

/// 앱에 내장한 OSM 슬로프·리프트 (tools/osm/build.py가 만든 maps/osm-<리조트>.json). R9, R50.
/// 좌표는 [위도, 경도]. 데이터: © OpenStreetMap contributors, ODbL.
nonisolated struct SlopeMap: Decodable {
    struct Slope: Decodable, Identifiable {
        let id: String          // 우리 ID (예: high1-s03). OSM ID는 바뀔 수 있어 참고용
        let name: String?
        let difficulty: String? // OSM piste:difficulty 값
        let osmIds: [String]
        let lines: [[[Double]]]
        let area: Bool?         // 면으로 그린 슬로프
    }

    struct Lift: Decodable, Identifiable {
        let id: String
        let name: String?
        let kind: String        // OSM aerialway 값
        let osmId: String
        let line: [[Double]]
    }

    let resortId: String
    let source: String
    let osmTimestamp: String
    let slopes: [Slope]
    let lifts: [Lift]

    /// 리조트별로 한 번만 읽는다.
    @MainActor static func cached(resortId: String) -> SlopeMap? {
        if let hit = cache[resortId] { return hit }
        let map = load(resortId: resortId)
        cache[resortId] = .some(map)
        return map
    }
    @MainActor private static var cache: [String: SlopeMap?] = [:]

    /// 지도 파일이 없는 리조트는 nil (R50: 목록 화면으로 대체).
    static func load(resortId: String, bundle: Bundle = .main) -> SlopeMap? {
        guard let url = bundle.url(forResource: "osm-\(resortId)", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SlopeMap.self, from: data)
    }
}
