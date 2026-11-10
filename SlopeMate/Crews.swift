import FirebaseFirestore
import Foundation

/// 내 크루와 크루원 (R14). 읽기는 보안 규칙이 허락한 Firestore 실시간 구독, 바꾸기는 모두 서버 함수(CrewAPI).
/// 나가거나 내보내지면 내 멤버 문서가 사라져 목록에서 바로 빠진다.
@Observable final class Crews {
    struct Crew: Identifiable, Equatable {
        let id: String
        var name: String
        var ownerUid: String
        var memberCount: Int
        var inviteToken: String
        var inviteURL: URL { Crews.inviteURL(inviteToken) }
    }

    struct Member: Identifiable, Equatable {
        let id: String
        var name: String
        var visitDays: Int
        var runs: Int
        var distanceKm: Double
        var resortDays: [String: Int]
        var joinedAt: Date
        /// 합계의 시즌. 지난 시즌 값이면 순위에서 0으로 본다(새 시즌 첫 동기화 전).
        var season: String
        var current: Member {
            guard season != HomeData.currentSeason() else { return self }
            var m = self; m.visitDays = 0; m.runs = 0; m.distanceKm = 0; m.resortDays = [:]; return m
        }
    }

    enum Metric: String, CaseIterable, Identifiable {
        case visitDays = "방문일", runs = "하강 횟수", distance = "거리"
        var id: Self { self }
    }

    static let maxMembers = 50
    static let maxOwned = 5

    private(set) var uid: String?
    private(set) var crews: [Crew] = []
    private(set) var members: [String: [Member]] = [:]
    enum Status { case loading, ready, failed }
    /// 내가 속한 크루 목록(멤버 문서)을 서버나 캐시에서 한 번이라도 받았는지. 받은 목록이 0개일 때만 S11을 보인다.
    private(set) var status = Status.loading
    /// 내가 속한 크루 ID(가입 순). 세부 정보(crews)가 아직 없거나 받지 못한 크루도 들어 있다.
    private(set) var ids: [String] = []
    /// 목록을 보여 주던 중 갱신이 끊겼는지
    private(set) var refreshFailed = false
    /// 세부 정보를 받지 못한 크루. 크루 문서와 순위(멤버) 구독은 따로 멈추므로 실패도 따로 센다.
    private(set) var failedDocs: Set<String> = []
    private(set) var failedMembers: Set<String> = []
    var failedCrews: Set<String> { failedDocs.union(failedMembers) }
    /// 초대 링크로 앱이 열렸을 때 크루 탭이 처리할 토큰
    var pendingInvite: String?

    @ObservationIgnored private var mine: ListenerRegistration?
    @ObservationIgnored private var perCrew: [String: [ListenerRegistration]] = [:]

    var ownedCount: Int { crews.filter { $0.ownerUid == uid }.count }
    /// 캐시 비우기에 실패해 이전 순위가 기기에 남아 있을 수 있음(다시 시도 대상)
    private(set) var purgeFailed = false
    var hasProblem: Bool { refreshFailed || purgeFailed || !failedCrews.isEmpty }

    /// 캐시 비우기가 끝나지 않았으면 다음에 다시 시도한다(앱을 다시 켜도 남는다).
    private var purgePending: Bool {
        get { UserDefaults.standard.bool(forKey: "crewCachePurgePending") }
        set { UserDefaults.standard.set(newValue, forKey: "crewCachePurgePending") }
    }
    @ObservationIgnored private var timeout: Task<Void, Never>?

    /// 로그인 상태가 바뀔 때마다 부른다. nil이면 구독을 모두 끊고 비운다.
    func follow(_ uid: String?) {
        guard uid != self.uid else { return }
        stop()
        self.uid = uid
        if purgePending { purgeCache() } else { start() }
    }

    /// 조회가 끊겼을 때(스냅샷 리스너는 오류가 나면 멈춘다) 처음부터 다시 구독한다. 남은 캐시 비우기도 다시 한다.
    func retry() {
        stop()
        if purgePending { purgeCache() } else { start() }
    }

    private func start() {
        guard let uid else { return }
        status = .loading
        // 캐시에 빈 목록만 있고 서버 확인이 오지 않으면(오프라인 첫 실행) S11 대신 오류와 다시 시도
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, status == .loading else { return }
            status = .failed
        }
        // 메타데이터 변경도 받아야 캐시 결과 뒤 서버 확인(fromCache=false)을 알 수 있다
        mine = Firestore.firestore().collectionGroup("members").whereField("uid", isEqualTo: uid)
            .addSnapshotListener(includeMetadataChanges: true) { [weak self] snap, _ in
                guard let self else { return }
                guard let snap else {
                    // 처음부터 못 받았으면 오류 화면, 보여 주던 중이면 마지막 목록 + 갱신 실패
                    if status == .ready { refreshFailed = true } else { status = .failed }
                    return
                }
                let rows = snap.documents.compactMap { d -> (String, Date)? in
                    guard let crewId = d.reference.parent.parent?.documentID else { return nil }
                    return (crewId, (d.get("joined_at") as? Timestamp)?.dateValue() ?? .distantFuture)
                }
                let next = rows.sorted { $0.1 < $1.1 }.map(\.0)
                // 서버에서 멤버 자격 상실(나가기·내보내짐)을 확인하면 그 크루의 순위가 기기 캐시에 남지 않게 비운다.
                // Firestore에는 문서 단위 캐시 삭제가 없어 캐시 전체를 비우고, 남은 크루는 곧바로 다시 받는다(온라인일 때만 확인되므로).
                if status == .ready, !snap.metadata.isFromCache, !Set(perCrew.keys).subtracting(next).isEmpty {
                    purgeCache()
                    return
                }
                // 서버가 확인하지 않은 빈 목록(빈 캐시)으로는 "크루 없음"(S11)을 정하지 않는다
                if snap.metadata.isFromCache && next.isEmpty && status != .ready { return }
                ids = next
                for gone in Set(perCrew.keys).subtracting(ids) { drop(gone) }
                for new in Set(ids).subtracting(perCrew.keys) { watch(new) }
                crews.sort { (self.ids.firstIndex(of: $0.id) ?? 0) < (self.ids.firstIndex(of: $1.id) ?? 0) }
                refreshFailed = false
                status = .ready
            }
    }

    /// 두 단계(종료 → 캐시 삭제)가 모두 성공해야 끝난 것으로 본다. 실패하면 표시를 남겨 다시 시도할 수 있게 한다.
    private func purgeCache() {
        stop()
        purgePending = true
        Firestore.firestore().terminate { error in
            guard error == nil else { return self.purgeFinished(ok: false) }
            Firestore.firestore().clearPersistence { error in self.purgeFinished(ok: error == nil) }
        }
    }

    private func purgeFinished(ok: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            purgeFailed = !ok
            // 실패하면 남은 캐시의 예전 멤버 목록으로 다시 구독하지 않도록 멈추고 오류 화면(다시 시도 = 캐시 비우기 재시도)
            guard ok else { status = .failed; return }
            purgePending = false
            start()
        }
    }

    private func stop() {
        mine?.remove(); mine = nil
        for id in Array(perCrew.keys) { drop(id) }
        timeout?.cancel()
        crews = []; members = [:]; ids = []; failedDocs = []; failedMembers = []; refreshFailed = false
        status = .loading
    }

    private func watch(_ id: String) {
        let ref = Firestore.firestore().collection("crews").document(id)
        let crewL = ref.addSnapshotListener { [weak self] snap, error in
            guard let self, perCrew[id] != nil else { return }
            guard let snap, snap.exists else {
                // 받지 못함(오류). 문서가 없으면 곧 멤버 목록에서도 빠진다.
                if error != nil { failedDocs.insert(id) }
                return
            }
            failedDocs.remove(id)
            let c = Crew(id: id, name: snap.get("name") as? String ?? "",
                         ownerUid: snap.get("owner_uid") as? String ?? "",
                         memberCount: snap.get("member_count") as? Int ?? 0,
                         inviteToken: snap.get("invite_token") as? String ?? "")
            if let i = crews.firstIndex(where: { $0.id == id }) { crews[i] = c } else { crews.append(c) }
            crews.sort { (self.ids.firstIndex(of: $0.id) ?? 0) < (self.ids.firstIndex(of: $1.id) ?? 0) }
        }
        let memL = ref.collection("members").addSnapshotListener { [weak self] snap, error in
            guard let self, perCrew[id] != nil else { return }
            guard let snap else { if error != nil { failedMembers.insert(id) }; return }
            failedMembers.remove(id)
            members[id] = snap.documents.map { d in
                Member(id: d.documentID, name: d.get("display_name") as? String ?? "",
                       visitDays: d.get("visit_days") as? Int ?? 0, runs: d.get("runs") as? Int ?? 0,
                       distanceKm: d.get("distance_km") as? Double ?? Double(d.get("distance_km") as? Int ?? 0),
                       resortDays: d.get("resort_days") as? [String: Int] ?? [:],
                       joinedAt: (d.get("joined_at") as? Timestamp)?.dateValue() ?? .now,
                       season: d.get("season") as? String ?? "").current
            }
        }
        perCrew[id] = [crewL, memL]
    }

    /// 구독을 끊고 화면에서 지운다. 기기 캐시는 자격 상실을 서버에서 확인했을 때 purgeCache가 비운다(05-design 6장).
    private func drop(_ id: String) {
        perCrew.removeValue(forKey: id)?.forEach { $0.remove() }
        crews.removeAll { $0.id == id }
        members[id] = nil
        failedDocs.remove(id)
        failedMembers.remove(id)
    }

    func crew(_ id: String) -> Crew? { crews.first { $0.id == id } }

    /// 기준별 순위. 같은 값이면 먼저 가입한 사람이 위.
    func ranking(_ id: String, by metric: Metric) -> [Member] {
        (members[id] ?? []).sorted {
            let (a, b) = (Self.value($0, metric), Self.value($1, metric))
            return a != b ? a > b : $0.joinedAt < $1.joinedAt
        }
    }

    static func value(_ m: Member, _ metric: Metric) -> Double {
        switch metric {
        case .visitDays: Double(m.visitDays)
        case .runs: Double(m.runs)
        case .distance: m.distanceKm
        }
    }

    /// S13 "방문일 3위"
    func myVisitRank(_ id: String) -> Int? {
        ranking(id, by: .visitDays).firstIndex { $0.id == uid }.map { $0 + 1 }
    }

    // MARK: 초대 링크

    /// 초대 링크 주소. 앱이 있으면 Universal Links로 앱이 열리고(초대 링크 단계), 없으면 웹페이지.
    static func inviteURL(_ token: String) -> URL {
        URL(string: "https://slopemate-f9a5b.web.app/i/\(token)")!
    }

    /// 붙여 넣은 링크나 토큰에서 토큰(22자)을 꺼낸다.
    static func token(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = URL(string: t).flatMap { $0.host != nil ? $0.lastPathComponent : nil } ?? t
        return candidate.range(of: "^[A-Za-z0-9_-]{22}$", options: .regularExpression) != nil ? candidate : nil
    }
}
