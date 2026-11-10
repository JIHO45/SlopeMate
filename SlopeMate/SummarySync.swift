import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import Network

/// 이번 시즌 합계를 크루 순위로 보낸다 (R15, R17). 보내는 것은 방문일·하강 횟수·거리·리조트별 방문일뿐이다.
/// 합계는 매번 기기 기록에서 새로 계산하므로 보내지 못한 값은 자연히 최신 값 하나로 합쳐지고,
/// 서버는 계산 시각(computed_at)이 저장된 값보다 늦을 때만 받는다. 크루에 속해 있을 때만 보낸다.
@Observable final class SummarySync {
    struct Payload: Equatable, Codable {
        var season: String
        var visitDays: Int
        var runs: Int
        var distanceKm: Double
        var resortDays: [String: Int]
    }

    /// 새로 설치한 기기: 이 기기에는 이번 시즌 기록이 없는데 서버에 합계가 있을 때 묻는다(05-design 4장).
    struct ServerOnly: Identifiable { let id = UUID(); var season: String; var visitDays: Int; var runs: Int }

    private(set) var failed = false
    private(set) var lastSynced: Date?
    var askReplace: ServerOnly?

    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    /// 작업 세대. 계정이 바뀌거나 삭제를 시작하면 올려서, 그 전에 시작한 작업의 늦은 결과를 버린다.
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private let path = NWPathMonitor()

    init(db: AppDatabase) {
        self.db = db
        // 앱을 열어 둔 채 연결이 돌아오면 실패한 합계를 다시 보낸다
        path.pathUpdateHandler = { [weak self] p in
            guard p.status == .satisfied else { return }
            DispatchQueue.main.async { if self?.failed == true { self?.sync() } }
        }
        path.start(queue: DispatchQueue(label: "SummarySync.path"))
    }

    /// 계정별로 따로 둔다(다른 계정으로 로그인해도 섞이지 않게)
    private enum Keys {
        static func lastSent(_ uid: String) -> String { "summaryLastSent-\(uid)" }      // 마지막으로 서버가 받은 Payload
        static func lastSynced(_ uid: String) -> String { "summaryLastSynced-\(uid)" }  // 그 시각(마지막 갱신)
        static func keepServer(_ uid: String, _ s: String) -> String { "summaryKeepServer-\(uid)-\(s)" }
    }

    private var uid: String? { Auth.auth().currentUser?.uid }

    /// 로그인 계정이 바뀌면 그 계정의 마지막 갱신 시각을 다시 읽는다.
    func follow(_ uid: String?) {
        invalidate()
        failed = false
        lastSynced = uid.flatMap { UserDefaults.standard.object(forKey: Keys.lastSynced($0)) as? Date }
    }

    /// 진행 중인 작업을 버린다(계정 변경, 계정 삭제 시작). 늦게 온 응답은 화면에도 기기에도 반영하지 않는다.
    func invalidate() {
        generation += 1
        again = false
        askReplace = nil
    }

    /// 계정 삭제 뒤: 그 계정의 동기화 상태를 기기에서 지운다.
    func forget(_ uid: String) {
        invalidate()
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("summary") && key.contains("-\(uid)") { d.removeObject(forKey: key) }
        failed = false
        lastSynced = nil
    }

    /// 이번 시즌 합계 (Stats 집계 규칙 그대로). 같은 날 두 리조트면 리조트별로는 각각 1일.
    nonisolated static func payload(_ db: AppDatabase, now: Date = .now) throws -> Payload {
        let season = HomeData.currentSeason(now: now)
        let days = Stats.days(try HomeData.days(db, since: HomeData.seasonStart(season)), inSeason: season)
        let t = Stats.totals(days)
        let byResort = Stats.totalsByResort(days).mapValues(\.visitDays).filter { $0.value > 0 }
        return Payload(season: season, visitDays: t.visitDays, runs: t.runs,
                       distanceKm: (t.distance / 100).rounded() / 10, resortDays: byResort)
    }

    /// 크루가 있을 때 앱이 켜질 때, 기록이 끝났을 때, 크루에 들어갔을 때 부른다. 겹쳐 부르면 한 번 더 돈다.
    func sync(force: Bool = false) {
        guard let uid else { return }
        if running { again = true; return }
        running = true
        let g = generation
        Task {
            defer {
                running = false
                if again { again = false; sync() }
            }
            do {
                let db = self.db
                let p = try await Task.detached { try Self.payload(db) }.value
                guard g == generation else { return }
                if !force, p == lastSent(uid) { failed = false; return }
                // 이 기기에 이번 시즌 기록이 없으면 서버 합계를 0으로 덮기 전에 묻는다
                if p.visitDays == 0 && p.runs == 0 && lastSent(uid)?.season != p.season {
                    if UserDefaults.standard.bool(forKey: Keys.keepServer(uid, p.season)) { failed = false; return }
                    let server = try await serverSummary(uid, p.season)
                    guard g == generation else { return }
                    if let server, server.visitDays > 0 || server.runs > 0 {
                        askReplace = server
                        return
                    }
                }
                try await send(p, uid, g)
            } catch {
                if g == generation { failed = true }
            }
        }
    }

    /// 새 설치 확인에 대한 답. 바꾸기를 고르면 이 기기 합계(0)로 보낸다.
    func answer(replace: Bool, season: String) {
        askReplace = nil
        guard let uid else { return }
        if replace {
            let g = generation
            Task {
                do { try await send(try Self.payload(db), uid, g) } catch { if g == generation { failed = true } }
            }
        } else {
            UserDefaults.standard.set(true, forKey: Keys.keepServer(uid, season))
        }
    }

    private func send(_ p: Payload, _ uid: String, _ g: Int) async throws {
        let r = try await CrewAPI.call("syncSummary", [
            "season": p.season, "visit_days": p.visitDays, "runs": p.runs, "distance_km": p.distanceKm,
            "resort_days": p.resortDays, "computed_at": Int(Date.now.timeIntervalSince1970 * 1000),
        ], as: uid)
        guard g == generation else { return }
        // 서버가 더 늦은 계산 시각의 합계를 이미 갖고 있으면(기기 시계를 뒤로 돌린 경우 등) 반영되지 않는다.
        // 받은 것으로 기록하지 않아 다음 계기에 다시 보내고, 화면에는 실패로 알린다.
        guard r["applied"] as? Bool == true else { throw SyncError.notApplied }
        UserDefaults.standard.set(try? JSONEncoder().encode(p), forKey: Keys.lastSent(uid))
        lastSynced = .now
        UserDefaults.standard.set(lastSynced, forKey: Keys.lastSynced(uid))
        failed = false
    }

    enum SyncError: Error { case notApplied }

    private func serverSummary(_ uid: String, _ season: String) async throws -> ServerOnly? {
        let doc = try await Firestore.firestore().collection("season_summaries").document("\(uid)_\(season)").getDocument()
        guard doc.exists else { return nil }
        return ServerOnly(season: season, visitDays: doc.get("visit_days") as? Int ?? 0, runs: doc.get("runs") as? Int ?? 0)
    }

    private func lastSent(_ uid: String) -> Payload? {
        UserDefaults.standard.data(forKey: Keys.lastSent(uid)).flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
    }

}
