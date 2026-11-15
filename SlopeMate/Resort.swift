import Foundation

struct Resort: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let homePageURL: URL
    let slopeStatusURL: URL
    let webCamURL: URL?
    /// 3D 처음 시점 리조트별 값(05-design 4장 "3D v5"). 키 없으면 nil
    let view3D: View3D?

    /// yaw·pitch: 도. excludeLifts: 처음 시점 맞춤에서 뺄 리프트 id(멀리 가는 이동용 곤돌라 등).
    /// zoom: 맞춘 거리에 곱하는 배수(기본 1, 0.4~1.5). 1보다 작으면 상자가 안전 영역보다 커져 가운데 기준으로 밖으로 나간다
    struct View3D: Codable, Hashable {
        var yaw: Double?
        var pitch: Double?
        var excludeLifts: [String]?
        var zoom: Double?
    }

    static let all: [Resort] = {
        let url = Bundle.main.url(forResource: "resorts", withExtension: "json")!
        return try! JSONDecoder().decode([Resort].self, from: Data(contentsOf: url))
    }()
}
