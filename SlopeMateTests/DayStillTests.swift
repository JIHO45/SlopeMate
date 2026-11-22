import Foundation
import Testing
@testable import SlopeMate

struct DayStillTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "DayStillTests-\(UUID().uuidString)")
    let day = Stats.Day(date: BusinessDay.start(of: Date(timeIntervalSince1970: 1_796_000_000)), resortId: "high1", runs: [], usedGPSAltitude: false)
    let rec = Recording(id: UUID(), resortId: "high1", startedAt: Date(timeIntervalSince1970: 1_796_000_000),
                        endedAt: Date(timeIntervalSince1970: 1_796_010_000), endReason: "user", vehicleQueriedAt: nil)

    @Test func keyStableAndChangesWithInputs() {
        let k = DayStill.key(day, recs: [rec], osm: "2026-11-01", build: "2")
        #expect(k == DayStill.key(day, recs: [rec], osm: "2026-11-01", build: "2"))
        #expect(k.hasPrefix("\(Int(day.date.timeIntervalSince1970))-high1-") && k.hasSuffix(".jpg"))
        var requeried = rec
        requeried.vehicleQueriedAt = Date(timeIntervalSince1970: 1_796_011_000)
        var reended = rec
        reended.endedAt = Date(timeIntervalSince1970: 1_796_012_000)
        let other = Recording(id: UUID(), resortId: "high1", startedAt: rec.startedAt, endedAt: rec.endedAt, endReason: nil, vehicleQueriedAt: nil)
        for changed in [DayStill.key(day, recs: [rec], osm: "2026-11-02", build: "2"),
                        DayStill.key(day, recs: [rec], osm: "2026-11-01", build: "3"),
                        DayStill.key(day, recs: [requeried], osm: "2026-11-01", build: "2"),
                        DayStill.key(day, recs: [reended], osm: "2026-11-01", build: "2"),
                        DayStill.key(day, recs: [rec, other], osm: "2026-11-01", build: "2")] {
            #expect(changed != k)
        }
    }

    @Test func removeDeletesOnlyThatDay() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ts = Int(day.date.timeIntervalSince1970)
        let mine = ["\(ts)-high1-0011223344556677.jpg", "\(ts)-high1-8899aabbccddeeff.jpg"]
        let others = ["\(ts)-high1-x-0011223344556677.jpg", "\(ts + 86_400)-high1-0011223344556677.jpg", "\(ts)-yongpyong-0011223344556677.jpg"]
        for name in mine + others { try Data([1]).write(to: dir.appending(path: name)) }
        DayStill.remove(day, dir: dir)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == Set(others))
    }
}
