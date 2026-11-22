import CryptoKit
import Foundation
import SceneKit
import UIKit

/// 기록 달력 주 카드 1장의 3D 정지 그림 (R55, D). 그날 하강 경로를 S19처럼(굵은 하강 선·흰 테두리·시작·끝 표시) 4:3으로 한 장 찍는다.
/// 늘 밝게(카드 위 유리 캡션과 맞춤). 방법은 홈 카드 Resort3DSnapshot과 같고, 아래 25% + 24pt는 캡션 자리로 비운다.
/// 파일 이름에 판정 기준·지도 시각·빌드·기록(차량 재판정 포함)의 지문을 넣어 하나라도 바뀌면 다시 만든다.
/// 렌더는 한 번에 하나씩, 차례가 왔을 때 더는 보지 않는 날은 건너뛴다
@MainActor enum DayStill {
    static let size = CGSize(width: 330, height: 248)
    /// 만드는 중인 하루: 카드가 다시 나타나도 두 번 만들지 않는다
    private static var making: [String: Task<UIImage?, Never>] = [:]
    /// 지금 그림을 기다리는 하루(image 호출이 취소되면 빠진다)
    private static var requested: Set<String> = []
    /// 렌더 줄의 마지막 작업
    private static var queue: Task<Void, Never>?
    /// 마지막 리조트의 지형. 장면마다 복사본을 넘겨 같은 리조트 날을 넘길 때 다시 만들지 않는다
    // ponytail: 리조트 하나만 둔다. 여러 리조트 날을 오가면 그때마다 다시 만든다
    private static var terrain: (resortId: String, space: Terrain3D, prepared: Map3DTerrain)?

    private nonisolated final class Entry: Sendable {
        let key: String, image: UIImage
        init(_ key: String, _ image: UIImage) { (self.key, self.image) = (key, image) }
    }
    /// day.id → (파일 이름, 그림). NSCache는 스레드 안전이라 nonisolated remove에서도 지운다
    private nonisolated(unsafe) static let memory: NSCache<NSString, Entry> = {
        let c = NSCache<NSString, Entry>()
        c.countLimit = 12
        return c
    }()

    nonisolated static var dir: URL {
        URL.cachesDirectory.appending(path: DemoSeed.on ? "DayStill-demo" : "DayStill", directoryHint: .isDirectory)
    }

    /// 메모리에 있는 그림만(바로 보여 주기용). 기록이 바뀌었어도 예전 그림일 수 있어 image로 다시 확인한다
    static func cached(_ day: Stats.Day) -> UIImage? { memory.object(forKey: day.id as NSString)?.image }

    /// 지도·지형이 없거나 하강이 없거나 렌더에 실패하면 nil. 기다리다 취소되면(카드가 사라짐) 차례가 와도 만들지 않고 nil
    static func image(_ day: Stats.Day, db: AppDatabase, dir: URL = dir) async -> UIImage? {
        guard let map = SlopeMap.cached(resortId: day.resortId), map.isDrawable else { return nil }
        requested.insert(day.id)
        let task: Task<UIImage?, Never>
        if let running = making[day.id] {
            task = running
        } else {
            let prev = queue
            task = Task {
                // 메모리·파일에 있으면 줄을 서지 않는다
                guard let found = await lookup(day, db: db, map: map, dir: dir) else { return nil }
                if let image = found.image { return image }
                await prev?.value
                guard requested.contains(day.id), !Task.isCancelled else { return nil }
                return await render(day, name: found.name, runs: found.runs, map: map, dir: dir)
            }
            making[day.id] = task
            queue = Task { _ = await task.value }
        }
        let image = await withTaskCancellationHandler { await task.value } onCancel: {
            Task { @MainActor in requested.remove(day.id) }
        }
        if making[day.id] == task { making[day.id] = nil }
        requested.remove(day.id)
        return image
    }

    /// 파일 이름. 지문: 판정 기준 버전, 지도 시각, 빌드 번호, 기록마다 id·끝난 시각·차량 조회 시각
    nonisolated static func key(_ day: Stats.Day, recs: [Recording], osm: String, build: String) -> String {
        var parts = ["\(RunDetector.rulesVersion)", osm, build]
        for r in recs {
            parts += [r.id.uuidString, "\(r.endedAt?.timeIntervalSince1970 ?? 0)", "\(r.vehicleQueriedAt?.timeIntervalSince1970 ?? 0)"]
        }
        let fp = SHA256.hash(data: Data(parts.joined(separator: "|").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(prefix(day))\(fp).jpg"
    }

    /// 기록 지우기: 그날 파일 전부·메모리 그림을 지우고 만드는 중이면 취소한다(지운 뒤 파일을 다시 쓰지 않게)
    nonisolated static func remove(_ day: Stats.Day, dir: URL = dir) {
        memory.removeObject(forKey: day.id as NSString)
        sweep(day, dir: dir)
        if Thread.isMainThread {
            MainActor.assumeIsolated { cancel(day) }
        } else {
            Task { @MainActor in cancel(day) }
        }
    }

    private static func cancel(_ day: Stats.Day) {
        making[day.id]?.cancel()
        requested.remove(day.id)
    }

    private nonisolated static func sweep(_ day: Stats.Day, dir: URL) {
        let p = prefix(day)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix(p) && !name.dropFirst(p.count).contains("-") {   // "a-b" 리조트 파일은 "a"로 지우지 않는다(지문은 16진수)
            try? FileManager.default.removeItem(at: dir.appending(path: name))
        }
    }

    private nonisolated static func prefix(_ day: Stats.Day) -> String { "\(Int(day.date.timeIntervalSince1970))-\(day.resortId)-" }

    private static let scale: CGFloat = 3

    /// 파일 이름과, 있으면 그림 또는 그릴 하강 경로. 기록·하강이 없으면 nil. DB·캐시·파일 읽기는 메인 밖에서
    private static func lookup(_ day: Stats.Day, db: AppDatabase, map: SlopeMap, dir: URL) async
        -> (name: String, image: UIImage?, runs: [RouteSegment])? {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let scale = scale
        return await Task.detached(priority: .utility) { () -> (name: String, image: UIImage?, runs: [RouteSegment])? in
            guard let recs = try? db.recordings(of: day), !recs.isEmpty else { return nil }
            let name = key(day, recs: recs, osm: AppDatabase.osmStamp(map), build: build)
            if let hit = memory.object(forKey: day.id as NSString), hit.key == name { return (name, hit.image, []) }
            if let data = try? Data(contentsOf: dir.appending(path: name)), let image = UIImage(data: data, scale: scale) {
                memory.setObject(Entry(name, image), forKey: day.id as NSString)
                return (name, image, [])
            }
            // 하강만 그린다(타고 오른 리프트 선은 빼서 S19처럼). 하강 0회면 그림 없음
            guard let runs = try? DayData.load(db, day, recs: recs, map: map).route.filter({ $0.kind == .run }), !runs.isEmpty else { return nil }
            return (name, nil, runs)
        }.value
    }

    private static func render(_ day: Stats.Day, name: String, runs: [RouteSegment], map: SlopeMap, dir: URL) async -> UIImage? {
        guard let cg = await snapshot(runs: runs, map: map, size: size, top: 0, bottom: size.height * 0.25 + 24, scale: scale) else { return nil }
        // 렌더 중에 기록을 지웠으면 쓰지 않는다
        // ponytail: 이 확인과 아래 파일 쓰기 사이에 지우면 파일 하나가 남는다(Caches, 다시 읽히지 않음)
        guard !Task.isCancelled else { return nil }
        let image = UIImage(cgImage: cg, scale: scale, orientation: .up)
        memory.setObject(Entry(name, image), forKey: day.id as NSString)
        await Task.detached(priority: .utility) {
            sweep(day, dir: dir)   // 예전 지문 파일 정리
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? image.jpegData(compressionQuality: 0.85)?.write(to: dir.appending(path: name), options: .atomic)
        }.value
        return image
    }

    /// 공유 이미지 3D 판(R31, 이용권): 같은 그림을 4:5로 다시 찍는다. 위는 SlopeMate, 아래는 패널·출처 자리. 캐시하지 않는다
    static func portrait(_ day: Stats.Day, db: AppDatabase) async -> UIImage? {
        guard let map = SlopeMap.cached(resortId: day.resortId), map.isDrawable else { return nil }
        guard let runs = await Task.detached(priority: .userInitiated, operation: { () -> [RouteSegment]? in
            guard let recs = try? db.recordings(of: day), !recs.isEmpty,
                  let runs = try? DayData.load(db, day, recs: recs, map: map).route.filter({ $0.kind == .run }), !runs.isEmpty else { return nil }
            return runs
        }).value else { return nil }
        guard let cg = await snapshot(runs: runs, map: map, size: ShareImage.size, top: ShareImage.top, bottom: ShareImage.bottom, scale: 2) else { return nil }
        return UIImage(cgImage: cg, scale: 2, orientation: .up)
    }

    /// 밝은 3D 장면에서 하강 경로에 맞춘 한 장. 지형은 마지막 리조트 것을 다시 쓴다
    private static func snapshot(runs: [RouteSegment], map: SlopeMap, size: CGSize, top: CGFloat, bottom: CGFloat, scale: CGFloat) async -> CGImage? {
        let space: Terrain3D, prepared: Map3DTerrain
        if let t = terrain, t.resortId == map.resortId {
            (space, prepared) = (t.space, t.prepared.stillCopy())
        } else {
            guard let built = await Task.detached(priority: .utility, operation: { () -> (Terrain3D, Map3DTerrain)? in
                guard let terrain = Terrain.load(resortId: map.resortId) else { return nil }
                let space = Terrain3D(terrain: terrain, map: map)
                return (space, Map3DTerrain(space: space, map: map))
            }).value else { return nil }
            terrain = (map.resortId, built.0, built.1)
            (space, prepared) = (built.0, built.1.stillCopy())
        }
        guard !Task.isCancelled else { return nil }
        // 다른 크기로 만든 뒤 setViewport로 바꿔야 처음 시점을 위 가림 0으로 다시 맞춘다(Resort3DSnapshot과 같음)
        let scene = Map3DScene(space: space, terrain: prepared, map: map, route: runs, dark: false,
                               viewport: CGSize(width: size.width, height: size.height * 2),
                               view3D: Resort.all.first { $0.id == map.resortId }?.view3D,
                               fitPoints: runs.flatMap(\.points).map { (lat: $0.lat, lon: $0.lon) })
        scene.setViewport(size, topInset: top, bottomInset: bottom, animated: false)
        scene.setLayers(MapLayers(slopes: true, lifts: false))
        scene.gestureEnded()   // 최종 크기의 1pt 길이로 경로 리본을 다시 만든다
        // 첫 렌더는 Metal 셰이더 컴파일로 오래 걸려 메인 밖에서. 장면은 이 함수 밖에서 아무도 건드리지 않는다
        let job = StillJob(scene: scene.scene, camera: scene.cameraNode,
                           pixels: CGSize(width: size.width * scale, height: size.height * scale))
        return await Task.detached(priority: .utility, operation: { job.render() }).value
    }
}

private extension Map3DTerrain {
    /// 메시 데이터는 나누고 재질은 따로 쓰는 복사(RunDetailView의 copy와 같음)
    func stillCopy() -> Map3DTerrain {
        var c = Map3DTerrain(sharing: geometry.copy() as! SCNGeometry, texture: texture)
        c.forest = forest?.copy() as? SCNGeometry
        return c
    }
    init(sharing geometry: SCNGeometry, texture: CGImage?) { self.geometry = geometry; self.texture = texture }
}

/// Resort3DSnapshot의 SnapshotJob 사본(그쪽은 private): 만든 장면을 넘겨받아 메인 밖에서 그린다
private nonisolated struct StillJob: @unchecked Sendable {
    let scene: SCNScene
    let camera: SCNNode
    let pixels: CGSize

    func render() -> CGImage? {
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        return renderer.snapshot(atTime: 0, with: pixels, antialiasingMode: .multisampling4X).cgImage
    }
}
