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
        /// 공중 리프트 지주 [위도, 경도], 선 방향(아래→위) 순서. 승·하차장 제외. 없으면 지면을 따라 그린다(tools/osm/pylons.py)
        let pylons: [[Double]]?
    }

    let resortId: String
    let source: String
    let osmTimestamp: String
    private(set) var slopes: [Slope]
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
        guard var map = try? decoder.decode(SlopeMap.self, from: data) else { return nil }
        if let url = bundle.url(forResource: "lines-\(resortId)", withExtension: "json"),
           let file = try? JSONDecoder().decode(DrawnFile.self, from: Data(contentsOf: url)) {
            map.slopes = drawn(file.lines, osm: map.slopes, resortId: resortId)
        }
        return map
    }

    /// 사용자가 그린 슬로프 선(tools/canopy/lines.py, lines-<리조트>.json). 있으면 OSM 선 대신 이것을 그리고 하강을 맞춘다.
    /// name: OSM 이름 대신 쓸 이름(사용자 대조, tools/canopy/line_fixes.py). closed: 이번 시즌 미운영이라 숨김(선은 남겨 다시 켤 수 있게)
    struct Drawn: Decodable {
        let slope: String?; let difficulty: String; let line: [[Double]]
        var name: String? = nil
        var closed: Bool? = nil
    }
    private struct DrawnFile: Decodable { let lines: [Drawn] }

    /// 그린 선을 슬로프로: 연결된 OSM 슬로프는 그 ID·이름(선에 name이 있으면 그것)·OSM ID에 그린 선(난이도는 그린 색), 연결 안 된 선은 새 슬로프(<리조트>-dNN, 이름은 선의 name).
    /// closed 선은 뺀다.
    /// 그리지 않은 OSM 슬로프는 뺀다(그린 리조트는 그린 것이 전부)
    static func drawn(_ lines: [Drawn], osm: [Slope], resortId: String) -> [Slope] {
        let lines = lines.filter { $0.closed != true }
        var out: [Slope] = []
        for s in osm {
            let all = lines.filter { $0.slope == s.id && $0.line.count > 1 }
            guard let first = all.first else { continue }
            let mine = all.filter { $0.difficulty == first.difficulty }   // 색이 다른 선은 아래에서 이름 없는 슬로프로
            out.append(Slope(id: s.id, name: mine.lazy.compactMap(\.name).first ?? s.name, difficulty: first.difficulty, osmIds: s.osmIds,
                             lines: mine.map(\.line), area: nil))
        }
        let firstColor = Dictionary(lines.compactMap { l in l.slope.map { ($0, l.difficulty) } }, uniquingKeysWith: { a, _ in a })
        let ids = Set(osm.map(\.id))
        let loose = lines.filter { l in l.line.count > 1 && (l.slope.map { !ids.contains($0) || firstColor[$0] != l.difficulty } ?? true) }
        for (i, l) in loose.enumerated() {
            out.append(Slope(id: "\(resortId)-d\(String(format: "%02d", i + 1))", name: l.name, difficulty: l.difficulty, osmIds: [], lines: [l.line], area: nil))
        }
        return out
    }
}
