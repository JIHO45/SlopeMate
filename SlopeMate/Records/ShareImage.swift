import SwiftUI
import UIKit

/// 하루 기록 공유 이미지 (R31; 확정 시안 공유 이미지 v5, decisions 2026-11-22).
/// 1080×1350(4:5) 한 장: 그날 그림(3D·2D 지도·사진, 없으면 하늘색 바탕) 위 왼쪽 위 "SlopeMate", 아래 한 줄 패널(리조트·날짜 | 하강 | 거리).
/// 지도·지형 그림이면 맨 아래 OSM·Copernicus 출처. 좌표·위치 메타데이터는 넣지 않는다(새로 그린 PNG). 공유를 누를 때만 만든다
enum ShareImage {
    /// 3D: 시즌 이용권, map: 이용권 없음(지형 바탕 + 내 경로), photo: 붙인 사진, plain: 지도 없는 기록
    enum Kind { case threeD, map, photo, plain
        /// 경로가 담겨 첫 공유 안내가 필요한 그림
        var hasRoute: Bool { self == .threeD || self == .map }
    }

    struct Content: Equatable {
        var date: String     // "2026. 12. 6. 일요일"
        var resort: String
        var runs: Int
        var distance: String // "8.3"
    }

    static let size = CGSize(width: 540, height: 675)
    /// 패널·출처 자리. 그림은 이 위에서 경로를 맞춘다
    static let top: CGFloat = 56, bottom: CGFloat = 150

    private static let dateFormat: DateFormatter = {
        let d = DateFormatter()
        d.locale = Locale(identifier: "ko_KR")
        d.timeZone = TimeZone(identifier: "Asia/Seoul")
        d.dateFormat = "yyyy. M. d. EEEE"
        return d
    }()

    static func content(_ day: Stats.Day, resort: String) -> Content {
        let km = RecordFormat.km(Stats.totals([day]).distance)
        return Content(date: dateFormat.string(from: day.date), resort: resort, runs: day.runs.count, distance: String(km.dropLast(2)))
    }

    /// 540×675pt를 2배로. 공유 이미지는 받는 사람 화면 설정과 관계없이 한 가지
    @MainActor static func render(_ c: Content, picture: UIImage?, credit: String?) -> UIImage? {
        let r = ImageRenderer(content: ShareImageView(c: c, picture: picture, credit: credit)
            .environment(\.colorScheme, .light).dynamicTypeSize(.large))
        r.scale = 2
        return r.uiImage
    }

    /// 그림을 못 만들면(지도·지형·하강 없음, 렌더 실패) 하늘색 바탕으로
    @MainActor static func make(_ kind: Kind, day: Stats.Day, db: AppDatabase) async -> UIImage? {
        let map = SlopeMap.cached(resortId: day.resortId)
        var picture: UIImage?
        switch kind {
        case .threeD: picture = await DayStill.portrait(day, db: db)
        case .map: picture = await mapPicture(day, db: db)
        case .photo: picture = await Task.detached(priority: .userInitiated) { DayPhoto.image(day) }.value
        case .plain: break
        }
        var credit: String?
        if picture != nil, kind.hasRoute, let map {
            credit = "© OpenStreetMap contributors"
            if Terrain.layer(map, dark: false) != nil { credit! += " · \(Terrain.source). \(Terrain.disclaimer)." }
        }
        return render(content(day, resort: Resort.name(day.resortId)), picture: picture, credit: credit)
    }

    /// 경로가 담긴 이미지·동영상을 처음 공유할 때 (S6·기록 달력 공통, 기기에 한 번)
    static let routeNotice = "이미지와 동영상 속 지도에 오늘 다닌 경로가 보여요. 받는 사람이 어느 슬로프를 탔는지 알 수 있어요."

    @MainActor static func share(_ kind: Kind, day: Stats.Day, db: AppDatabase) async {
        guard let image = await make(kind, day: day, db: db) else { return }
        ShareSheet.present([image])
    }

    /// 2D 지도 판: 지형 바탕 + 내 경로. 슬로프·리프트 선은 공유 동영상처럼 그리지 않는다
    @MainActor static func mapPicture(_ day: Stats.Day, db: AppDatabase) async -> UIImage? {
        guard let map = SlopeMap.cached(resortId: day.resortId), map.isDrawable else { return nil }
        guard let route = await Task.detached(priority: .userInitiated, operation: { () -> [RouteSegment]? in
            guard let recs = try? db.recordings(of: day), !recs.isEmpty,
                  let route = try? DayData.load(db, day, recs: recs, map: map).route, !route.isEmpty else { return nil }
            return route
        }).value else { return nil }
        let ground = await Terrain.ground(map)
        let drawing = DayMapDrawing(map: map, route: route, dark: false,
                                    terrain: Terrain.layer(map, dark: false)?.with(ground: ground), layers: .none)
        let proj = MapProjection(map, rect: CGRect(x: 24, y: top, width: size.width - 48, height: size.height - top - bottom))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image {
            drawing.draw($0.cgContext, size: size, proj, now: nil, unit: size.width / 390)
        }
    }
}

/// 540×675pt. 글자 크기는 이미지 안에서 고정이라 Dynamic Type을 따르지 않는다.
/// ImageRenderer는 흐림 재질을 그리지 못해 패널은 반투명 진한 면 + 흰 테두리
private struct ShareImageView: View {
    let c: ShareImage.Content
    let picture: UIImage?
    let credit: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let picture {
                Image(uiImage: picture).resizable().scaledToFill()
                    .frame(width: ShareImage.size.width, height: ShareImage.size.height).clipped()
                // 눈·하늘처럼 밝은 그림에서도 로고·패널·출처가 읽히게 위아래를 옅게 어둡게
                LinearGradient(stops: [.init(color: .black.opacity(0.25), location: 0), .init(color: .clear, location: 0.16),
                                       .init(color: .clear, location: 0.66), .init(color: .black.opacity(0.4), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: [Color(red: 0.81, green: 0.91, blue: 0.94), Color(red: 0.96, green: 0.98, blue: 0.98)],
                               startPoint: .top, endPoint: .bottom)
            }
            // 그림 위는 흰 글씨 + 옅은 그림자, 하늘색 바탕 위는 강조색
            Text("SlopeMate").font(.system(size: 18, weight: .heavy))
                .foregroundStyle(picture == nil ? Color(red: 0x08 / 255, green: 0x74 / 255, blue: 0x80 / 255) : .white)
                .shadow(color: .black.opacity(picture == nil ? 0 : 0.3), radius: 2, y: 1)
                .padding(.leading, 24).padding(.top, 20)
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                panel
                if let credit {
                    Text(credit).font(.system(size: 8)).foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, credit == nil ? 40 : 12)
        }
        .frame(width: ShareImage.size.width, height: ShareImage.size.height)
    }

    private var panel: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(c.resort).font(.system(size: 22, weight: .bold))
                Text(c.date).font(.system(size: 14)).opacity(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            (Text("\(c.runs)").font(.system(size: 40, weight: .heavy)).tracking(-1) + Text("회").font(.system(size: 20, weight: .heavy)))
            Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 32)
            Text(c.distance).font(.system(size: 26, weight: .bold)) + Text("km").font(.system(size: 15, weight: .bold))
        }
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .frame(height: 76)
        .background(Color(red: 10 / 255, green: 30 / 255, blue: 36 / 255).opacity(0.55), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.45)))
    }
}

#Preview("공유 이미지 · 바탕") {
    ShareImageView(c: .init(date: "2026. 12. 20. 일요일", resort: "하이원", runs: 10, distance: "13.6"), picture: nil,
                   credit: "© OpenStreetMap contributors · \(Terrain.source). \(Terrain.disclaimer).")
}
