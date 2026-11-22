import Foundation

/// 앱 업데이트 없이 바꾸는 설정 (Firebase Hosting `hosting/public`, R7·R9, 05-design 5장).
/// 앱이 앞에 있는 동안 1시간에 한 번 받아 기기에 저장한다(켤 때·다시 볼 때 마지막으로 받은 지 1시간이 지났으면 바로). 받지 못하거나 형식이 틀리면 마지막으로 받은 값, 처음이면 기본값을 쓴다.
enum ServerConfig {
    nonisolated struct Config: Codable, Equatable {
        /// 슬로프 이름을 보여 줄 리조트(R9). 없으면 꺼짐.
        var slopeNames: [String]
        /// false면 시즌 합계를 보내지 않는다(비용 차단 스위치)
        var crewSync: Bool
        /// false면 익명 표본을 보내지 않는다(R12, 표본 전송을 붙일 때 사용). 차단 스위치라 기본은 true이고,
        /// 실제로 보낼지는 사용자 동의(설정의 익명 전송)가 정한다.
        var samples: Bool
        /// false면 3D 하강 상세의 리프트 이름표를 숨긴다(오표기 차단 스위치, decisions 2026-11-16). 키가 없는 예전 파일도 켜짐으로 읽는다
        var placeNames: Bool = true
        /// true면 내 리프트 대기(R32)를 S6·S9·S18에 보인다. R10 오차가 기준 안에 들어온 뒤 켠다. 키가 없는 예전 파일은 꺼짐
        var liftWait: Bool = false

        init(slopeNames: [String], crewSync: Bool, samples: Bool, placeNames: Bool = true, liftWait: Bool = false) {
            (self.slopeNames, self.crewSync, self.samples, self.placeNames, self.liftWait) = (slopeNames, crewSync, samples, placeNames, liftWait)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            slopeNames = try c.decode([String].self, forKey: .slopeNames)
            crewSync = try c.decode(Bool.self, forKey: .crewSync)
            samples = try c.decode(Bool.self, forKey: .samples)
            placeNames = try c.decodeIfPresent(Bool.self, forKey: .placeNames) ?? true
            liftWait = try c.decodeIfPresent(Bool.self, forKey: .liftWait) ?? false
        }
    }

    static let base = URL(string: "https://slopemate-f9a5b.web.app")!
    static let defaults = Config(slopeNames: [], crewSync: true, samples: true)
    private static let configKey = "serverConfig"
    private static let nextKey = "serverConfigNextAttempt"

    static var config: Config {
        UserDefaults.standard.data(forKey: configKey).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? defaults
    }

    /// 세션 분류에 쓰는 시간표: 앱 내장 + 서버. 같은 리조트·기간이 겹치면 version이 큰 것(Timetable.session).
    static var timetables: [Timetable] { Timetable.all + server }
    private static var server: [Timetable] = (try? Data(contentsOf: timetablesFile)).flatMap { try? Timetable.decode($0) } ?? []
    private static var timetablesFile: URL {
        URL.applicationSupportDirectory.appending(path: "server-timetables.json")
    }

    static let interval: TimeInterval = 3600
    static let retry: TimeInterval = 300

    /// 다음 조회 시각. 받으면 1시간 뒤, 받지 못하면(오프라인 등) 5분 뒤. 앱을 다시 열어도, 타이머로 돌아와도 이 시각을 따른다.
    private static var nextAttempt: Date? {
        get { UserDefaults.standard.object(forKey: nextKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: nextKey) }
    }

    /// 조회 결과로 다음 조회 시각을 정한다
    static func next(after now: Date, ok: Bool) -> Date { now.addingTimeInterval(ok ? interval : retry) }

    /// 다음 조회까지 기다릴 시간(이미 지났으면 0)
    static func secondsUntilRefresh(next: Date? = nextAttempt, now: Date = .now) -> TimeInterval {
        max(next?.timeIntervalSince(now) ?? 0, 0)
    }

    /// 다음 조회 시각이 되었을 때만 받는다(켤 때·다시 볼 때·타이머 모두 여기서 거른다).
    static func refresh() async {
        guard secondsUntilRefresh() == 0 else { return }
        async let c = fetch("config.json")
        async let t = fetch("timetables.json")
        let (configData, timetableData) = await (c, t)
        // 성공은 두 파일을 모두 해석했을 때만. 잘못된 파일을 올렸다 바로 고쳐도 5분 안에 다시 받는다.
        var ok = true
        if let configData, let cfg = try? JSONDecoder().decode(Config.self, from: configData) {
            apply(cfg, data: configData)
        } else { ok = false }
        if let timetableData, let list = try? Timetable.decode(timetableData) {
            try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            try? timetableData.write(to: timetablesFile, options: .atomic)
            server = list
        } else { ok = false }
        nextAttempt = next(after: .now, ok: ok)
    }

    static func apply(_ cfg: Config, data: Data) {
        UserDefaults.standard.set(data, forKey: configKey)
        SlopeNames.update(Dictionary(cfg.slopeNames.map { ($0, true) }, uniquingKeysWith: { a, _ in a }))
    }

    private static func fetch(_ name: String) async -> Data? {
        var req = URLRequest(url: base.appending(path: name), timeoutInterval: 15)
        req.cachePolicy = .reloadRevalidatingCacheData
        guard let (data, res) = try? await URLSession.shared.data(for: req),
              (res as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
