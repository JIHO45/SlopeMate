import Foundation
import Testing
import UIKit
@testable import SlopeMate

@MainActor struct ShareImageTests {
    let f = ISO8601DateFormatter()
    func at(_ s: String) -> Date { f.date(from: s + "+09:00")! }
    func run(_ start: String, _ end: String) -> RunDetector.Run {
        RunDetector.Run(start: at(start), end: at(end), distance: 1200, drop: 300, maxSpeed: 15, avgSpeed: 8, movingTime: 150)
    }
    var day: Stats.Day {
        Stats.Day(date: at("2026-12-06T06:00:00"), resortId: "high1", runs: [
            run("2026-12-06T09:40:00", "2026-12-06T09:45:00"), run("2026-12-06T16:15:00", "2026-12-06T16:20:00"),
            run("2026-12-06T18:30:00", "2026-12-06T18:35:00"),
            run("2026-12-06T22:40:00", "2026-12-06T22:45:00"), run("2026-12-07T01:25:00", "2026-12-07T01:30:00"),
            run("2026-12-06T17:00:00", "2026-12-06T17:05:00")], usedGPSAltitude: false)
    }

    @Test func contentIsDateResortRunsDistance() {
        let c = ShareImage.content(day, resort: "하이원")
        #expect(c == .init(date: "2026. 12. 6. 일요일", resort: "하이원", runs: 6, distance: "7.2"))
    }

    @Test func rendersAt1080x1350WithAndWithoutPicture() throws {
        let c = ShareImage.content(day, resort: "하이원")
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { $0.fill(CGRect(x: 0, y: 0, width: 400, height: 300)) }
        for image in [ShareImage.render(c, picture: nil, credit: nil), ShareImage.render(c, picture: photo, credit: "© OpenStreetMap contributors")] {
            let image = try #require(image)
            #expect(image.size.width * image.scale == 1080)
            #expect(image.size.height * image.scale == 1350)
        }
    }

    @Test func onlyMapPicturesCarryRoute() {
        #expect(ShareImage.Kind.threeD.hasRoute && ShareImage.Kind.map.hasRoute)
        #expect(!ShareImage.Kind.photo.hasRoute && !ShareImage.Kind.plain.hasRoute)
    }
}
