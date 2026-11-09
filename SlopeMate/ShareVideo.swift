import AVFoundation
import SwiftUI
import UIKit

/// 하루 기록 공유 동영상 (R50, K; 동영상 만드는 중 v1, 첫 공유 안내 v1).
/// 화면과 같은 그리기 코드로 프레임을 그려 12초 세로 H.264로 만든다. 공유를 누를 때만 만들고, 공유·취소·실패 뒤 임시 파일을 지운다.
nonisolated enum ShareVideo {
    static let seconds = 12
    static let fps = 30

    /// 프레임에 들어갈 것. 글자는 메인에서 미리 만든다
    struct Content {
        var drawing: DayMapDrawing
        var clock: PlayClock
        var title: String    // "11월 7일 · 하이원"
        var count: String    // "9회"
        var summary: String  // "12.3km · 고도차 1,500m · 최고 54km/h"
    }

    private static let hm: DateFormatter = {
        let d = DateFormatter()
        d.locale = Locale(identifier: "ko_KR")
        d.timeZone = TimeZone(identifier: "Asia/Seoul")
        d.dateFormat = "HH:mm"
        return d
    }()

    /// 임시 폴더에 만든 파일. 취소(Task 취소)·실패하면 파일을 지우고 던진다
    @concurrent static func make(_ c: Content, size: CGSize = CGSize(width: 1080, height: 1920), seconds: Int = seconds, fps: Int = fps,
                     progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
        // 공유 중 앱이 끝나 남은 지난 파일
        for old in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where old.hasPrefix("SlopeMate-") && old.hasSuffix(".mp4") {
            try? FileManager.default.removeItem(at: tmp.appending(path: old))
        }
        let url = tmp.appending(path: "SlopeMate-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(input)
        do {
            guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            writer.startSession(atSourceTime: .zero)
            let n = seconds * fps
            for i in 0..<n {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                var buf: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf)
                guard let buf else { throw CocoaError(.fileWriteUnknown) }
                CVPixelBufferLockBaseAddress(buf, [])
                let cg = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                if let cg {
                    cg.translateBy(x: 0, y: size.height)
                    cg.scaleBy(x: 1, y: -1)
                    frame(cg, c, size: size, progress: Double(i) / Double(n - 1))
                }
                CVPixelBufferUnlockBaseAddress(buf, [])
                guard cg != nil, adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                progress(Double(i + 1) / Double(n))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)))
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            return url
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// 프레임 1장: 위에 날짜·리조트와 재생 시각, 가운데 지도, 아래 합계와 OSM 출처. 위가 0인 좌표계
    static func frame(_ cg: CGContext, _ c: Content, size: CGSize, progress p: Double) {
        let u = size.width / 390
        let proj = MapProjection(c.drawing.map, rect: CGRect(x: 24 * u, y: 130 * u, width: size.width - 48 * u, height: size.height - 290 * u))
        let now = c.clock.time(at: p)
        c.drawing.draw(cg, size: size, proj, now: now, unit: u)

        let pal = DayMapDrawing.Palette(dark: c.drawing.dark)
        UIGraphicsPushContext(cg)
        defer { UIGraphicsPopContext() }
        func text(_ s: String, _ pt: CGPoint, _ font: UIFont, _ color: UIColor, right: Bool = false) {
            let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let w = right ? (s as NSString).size(withAttributes: a).width : 0
            (s as NSString).draw(at: CGPoint(x: pt.x - w, y: pt.y), withAttributes: a)
        }
        let digits = UIFont.monospacedDigitSystemFont(ofSize: 22 * u, weight: .semibold)
        text(c.title, CGPoint(x: 24 * u, y: 56 * u), .systemFont(ofSize: 22 * u, weight: .bold), pal.primary)
        if let now { text(hm.string(from: now), CGPoint(x: size.width - 24 * u, y: 56 * u), digits, pal.text, right: true) }
        text(c.count, CGPoint(x: 24 * u, y: size.height - 140 * u), .monospacedDigitSystemFont(ofSize: 34 * u, weight: .bold), pal.text)
        text(c.summary, CGPoint(x: 24 * u, y: size.height - 96 * u), .systemFont(ofSize: 15 * u), pal.label)
        text("© OpenStreetMap contributors", CGPoint(x: size.width - 24 * u, y: size.height - 44 * u), .systemFont(ofSize: 12 * u), pal.label, right: true)
    }

    /// 만드는 중 창의 세로 썸네일: 마지막 프레임
    static func thumbnail(_ c: Content, size: CGSize = CGSize(width: 72, height: 128)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { frame($0.cgContext, c, size: size, progress: 1) }
    }
}

/// 만드는 중 창: 세로 썸네일, 진행률, 취소 (S6 위 가운데)
struct ShareMakingView: View {
    var thumbnail: UIImage?
    var progress: Double
    var cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().accessibilityHidden(true)
            VStack(spacing: 6) {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.cardBorder))
                        .accessibilityHidden(true)
                }
                Text("동영상을 만드는 중이에요").font(.headline).padding(.top, 14)
                Text("오늘 하루를 \(ShareVideo.seconds)초 세로 동영상으로 만들어요.").font(.subheadline).foregroundStyle(Color.secondaryText)
                HStack(spacing: 10) {
                    ProgressView(value: progress).tint(Color.accentFill).accessibilityLabel("동영상 만들기")
                    Text("\(Int(progress * 100))%").font(.subheadline.weight(.semibold)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .padding(.top, 12)
                Button(action: cancel) {
                    Text("취소").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                }
                .foregroundStyle(Color.primaryText)
                .background(Color.primaryText.opacity(0.07), in: Capsule())
                .padding(.top, 14)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.primaryText)
            .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 16)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 32))
            .padding(.horizontal, 45)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}

/// 공유 시트를 맨 위 화면에서 띄우고, 끝나면(보냈든 닫았든) 파일을 지운다
@MainActor enum ShareSheet {
    static func present(_ url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: url) }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
    }
}
