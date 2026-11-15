import Foundation
import Testing
import UIKit
@testable import SlopeMate

/// S6 시즌 이용권 잠금(R54·R50, decisions 2026-11-14): 그 하루 기록 시즌으로 판단
struct DayMapLockTests {
    func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "T12:00:00+09:00")! }
    let now = ISO8601DateFormatter().date(from: "2026-12-10T12:00:00+09:00")!

    @Test func bySeasonOfDay() {
        #expect(DayMapView.lock(day: at("2026-12-05"), owned: [], now: now) == .ticket)
        #expect(DayMapView.lock(day: at("2026-12-05"), owned: ["2026-27"], now: now) == .open)
        // 지난 시즌: 그 시즌 이용권이 있으면 열리고, 없으면 S18 대신 안내. 이번 시즌 이용권으로는 안 열림
        #expect(DayMapView.lock(day: at("2026-02-01"), owned: ["2025-26"], now: now) == .open)
        #expect(DayMapView.lock(day: at("2026-02-01"), owned: ["2026-27"], now: now) == .pastSeason)
    }

    /// 경계: 4/30은 지난 시즌, 5/1·7월(시즌 밖)은 이번 시즌, 11/1은 새 시즌
    @Test func boundaries() {
        #expect(DayMapView.lock(day: at("2026-04-30"), owned: [], now: now) == .pastSeason)
        #expect(DayMapView.lock(day: at("2026-04-30"), owned: ["2025-26"], now: now) == .open)
        #expect(DayMapView.lock(day: at("2026-05-01"), owned: [], now: now) == .ticket)
        #expect(DayMapView.lock(day: at("2026-05-01"), owned: ["2026-27"], now: now) == .open)
        #expect(DayMapView.lock(day: at("2026-11-01"), owned: ["2026-27"], now: now) == .open)
        #expect(DayMapView.lock(day: at("2026-11-01"), owned: ["2025-26"], now: now) == .ticket)
        // 7월 기록을 7월에 보면 이용권 시즌(달력 기준 2026-27)
        let july = at("2026-07-20")
        #expect(DayMapView.lock(day: at("2026-07-15"), owned: ["2026-27"], now: july) == .open)
        #expect(DayMapView.lock(day: at("2026-07-15"), owned: ["2025-26"], now: july) == .ticket)
    }

    /// 워터마크를 켜면 프레임이 바뀌고, 바뀐 자리는 가장 긴 합계 줄(아래 96pt부터)보다 위
    @MainActor @Test func watermarkClearOfSummary() throws {
        let map = try #require(SlopeMap.load(resortId: "high1"))
        let size = ShareVideo.size(hd: false), u = size.width / 390
        func frame(_ watermark: Bool) -> CGImage {
            let d = DayMapDrawing(map: map, route: [], dark: true, terrain: Terrain.layer(map, dark: true))
            let c = ShareVideo.Content(drawing: d, clock: PlayClock([]), title: "11월 7일 · 하이원", count: "99회",
                                       summary: "102.4km · 고도차 12,036m · 최고 102km/h", watermark: watermark)
            let f = UIGraphicsImageRendererFormat()
            f.scale = 1
            return UIGraphicsImageRenderer(size: size, format: f).image { ShareVideo.frame($0.cgContext, c, size: size, progress: 1) }.cgImage!
        }
        let a = frame(false), b = frame(true)
        let pa = a.dataProvider!.data! as Data, pb = b.dataProvider!.data! as Data
        let rows = (0..<a.height).filter { y in
            let r = y * a.bytesPerRow..<(y + 1) * a.bytesPerRow
            return pa[r] != pb[r]
        }
        let last = try #require(rows.last)
        #expect(CGFloat(last) < size.height - 96 * u)
        #expect(CGFloat(rows.first!) >= size.height - 140 * u)
    }

    @Test func videoSize() {
        #expect(ShareVideo.size(hd: false) == CGSize(width: 720, height: 1280))
        #expect(ShareVideo.size(hd: true) == CGSize(width: 1080, height: 1920))
    }
}
