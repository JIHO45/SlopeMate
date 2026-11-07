import Foundation

struct Resort: Codable, Identifiable, Hashable {
    struct Hours: Codable, Hashable {
        let day: String
        let night: String?
        let lateNight: String?
    }

    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let homePageURL: URL
    let slopeStatusURL: URL
    let webCamURL: URL?
    let hours: Hours

    static let all: [Resort] = {
        let url = Bundle.main.url(forResource: "resorts", withExtension: "json")!
        return try! JSONDecoder().decode([Resort].self, from: Data(contentsOf: url))
    }()
}
