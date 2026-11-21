import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import SlopeMate

struct DayPhotoTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "DayPhotoTests-\(UUID().uuidString)")
    let day = Stats.Day(date: BusinessDay.start(of: Date(timeIntervalSince1970: 1_796_000_000)), resortId: "high1", runs: [], usedGPSAltitude: false)

    /// 4000×3000 JPEG, GPS 메타데이터 포함
    func photo() -> Data {
        let ctx = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(UIColor.systemBlue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.2, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 128.8, kCGImagePropertyGPSLongitudeRef: "E"],
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func props(_ data: Data) -> [CFString: Any] {
        CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil) as! [CFString: Any]
    }

    @Test func saveShrinksAndStripsLocation() throws {
        let src = photo()
        #expect(props(src)[kCGImagePropertyGPSDictionary] != nil)
        #expect(DayPhoto.image(day, dir: dir) == nil && !DayPhoto.exists(day, dir: dir))

        try DayPhoto.save(src, for: day, dir: dir)
        #expect(DayPhoto.exists(day, dir: dir))
        let saved = props(try Data(contentsOf: DayPhoto.url(day, dir: dir)))
        #expect(saved[kCGImagePropertyGPSDictionary] == nil)
        #expect(max(saved[kCGImagePropertyPixelWidth] as! Int, saved[kCGImagePropertyPixelHeight] as! Int) <= DayPhoto.maxPixel)

        let full = try #require(DayPhoto.image(day, dir: dir))
        #expect(max(full.size.width, full.size.height) * full.scale <= 1600)
        let thumb = try #require(DayPhoto.image(day, maxPixel: 120, dir: dir))
        #expect(max(thumb.size.width, thumb.size.height) * thumb.scale <= 120)

        DayPhoto.delete(day, dir: dir)
        #expect(DayPhoto.image(day, dir: dir) == nil && !DayPhoto.exists(day, dir: dir))
    }

    @Test func garbageThrows() {
        #expect(throws: (any Error).self) { try DayPhoto.save(Data("not an image".utf8), for: day, dir: dir) }
        #expect(!DayPhoto.exists(day, dir: dir))
    }
}
