import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 하루 기록 대표 사진 1장(R55). 이 기기에만, 긴 변 1600px JPEG, 위치 등 메타데이터 없이 저장한다.
nonisolated enum DayPhoto {
    static let maxPixel = 1600

    static var dir: URL {
        URL.applicationSupportDirectory.appending(path: DemoSeed.on ? "DayPhotos-demo" : "DayPhotos", directoryHint: .isDirectory)
    }

    static func url(_ day: Stats.Day, dir: URL = dir) -> URL {
        dir.appending(path: "\(Int(day.date.timeIntervalSince1970))-\(day.resortId).jpg")
    }

    struct Undecodable: Error {}

    static func save(_ data: Data, for day: Stats.Day, dir: URL = dir) throws {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = thumbnail(src, maxPixel) else { throw Undecodable() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw Undecodable() }
        // 원본 속성을 넘기지 않으므로 EXIF·GPS가 남지 않는다
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Undecodable() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (out as Data).write(to: url(day, dir: dir), options: .atomic)
    }

    static func image(_ day: Stats.Day, maxPixel: Int? = nil, dir: URL = dir) -> UIImage? {
        let u = url(day, dir: dir)
        guard let maxPixel else { return UIImage(contentsOfFile: u.path) }
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), let img = thumbnail(src, maxPixel) else { return nil }
        return UIImage(cgImage: img)
    }

    static func exists(_ day: Stats.Day, dir: URL = dir) -> Bool {
        FileManager.default.fileExists(atPath: url(day, dir: dir).path)
    }

    static func delete(_ day: Stats.Day, dir: URL = dir) {
        try? FileManager.default.removeItem(at: url(day, dir: dir))
    }

    private static func thumbnail(_ src: CGImageSource, _ maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }
}
