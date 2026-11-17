import AuthenticationServices
import FirebaseAuth
import FirebaseFunctions
import Foundation
import UIKit

/// 계정 삭제 (R13, 05-design 6장). 순서: Apple 재로그인 → 재인증 → Apple 연결 해제 → 서버 삭제 → 기기 정리.
/// 어디까지 했는지 기기에 남겨 앱이 중간에 꺼져도 이어서 한다. 완료는 서버가 확인해 줬을 때만 알린다.
/// 기기의 스키 기록·시즌권·설정은 건드리지 않는다. 지우는 것은 대기 중인 익명 표본, 크루 캐시, 계정별 동기화 상태뿐이다.
@Observable final class AccountDeletion {
    enum Phase: Equatable { case idle, confirm, working, done, failed }
    /// 기기에 남기는 진행 표시. 재인증 직후(해제 전)에 만들고, 해제에 성공하면 revoked, 서버가 삭제를 확인하면 serverDone을 켠다.
    /// 기기 정리까지 끝나야 지운다. 사용자가 시트를 닫아도 지우지 않는다(해제가 이미 됐을 수 있음).
    struct Pending: Codable, Equatable { var uid: String; var revoked: Bool; var serverDone = false }
    enum Step: Equatable { case none, reauth, callServer, checkStatus, cleanUp }

    var phase = Phase.idle
    let account: Account
    @ObservationIgnored private let crews: Crews
    @ObservationIgnored private let summary: SummarySync
    @ObservationIgnored private let db: AppDatabase

    init(account: Account, crews: Crews, summary: SummarySync, db: AppDatabase) {
        self.account = account; self.crews = crews; self.summary = summary; self.db = db
    }

    private static let key = "accountDeletePending"
    private(set) var pending: Pending? {
        get { UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.key) }
    }

    /// 다음에 할 일. 해제 여부를 모르면 Apple 창부터 다시(두 번 해제해도 안전), 해제했으면 서버만 다시 부르고,
    /// 그 계정으로 로그인해 있지 않으면(지워져서 로그아웃됐을 수 있음) 서버에 상태를 묻는다. 로그아웃만으로 완료라고 보지 않는다.
    static func next(_ pending: Pending?, signedIn uid: String?) -> Step {
        guard let pending else { return .none }
        if pending.serverDone { return .cleanUp }
        if !pending.revoked { return .reauth }
        return uid == pending.uid ? .callServer : .checkStatus
    }

    private var step: Step { Self.next(pending, signedIn: Auth.auth().currentUser?.uid) }

    /// Apple 창부터 다시 해야 한다는 시트는 앱을 켤 때 한 번만 띄운다(다시 볼 때마다 띄우지 않음)
    @ObservationIgnored private var askedThisLaunch = false

    /// 앱을 켜거나 다시 볼 때: 끝내지 못한 삭제를 잇는다. 끝났거나 사용자가 다시 해야 할 때만 시트를 띄운다.
    @MainActor func resume() async {
        guard phase == .idle else { return }
        switch step {
        case .none: return
        case .cleanUp: await cleanUp()
        case .reauth:
            guard !askedThisLaunch else { return }
            askedThisLaunch = true
            phase = .failed
        case .callServer: await finish(quiet: true)
        case .checkStatus: await check(quiet: true)
        }
    }

    /// 확인 시트의 "계정 삭제"와 실패 시트의 "다시 시도"
    @MainActor func proceed() async {
        switch step {
        case .none, .reauth: await start()
        case .callServer: await finish(quiet: false)
        case .checkStatus: await check(quiet: false)
        case .cleanUp: await cleanUp()
        }
    }

    /// 시트를 닫는다. 진행 표시는 남겨 다음에 잇는다(설정의 "계정 삭제"로 다시 시작할 수도 있다).
    func close() {
        phase = .idle
    }

    @MainActor private func start() async {
        let before = phase
        phase = .working
        // 다시 로그인하는 동안 가입 확인이 로그아웃시키지 않게(계정 문서가 없는 계정도 지울 수 있어야 함)
        account.holdCheck = true
        defer { account.holdCheck = false }
        do {
            let auth = try await AppleAuth.authorize(prepare: account.prepare)
            let (credential, code) = try account.credential(auth)
            // 로그아웃된 채 다시 하는 경우(서버에 접수되지 않았음을 확인한 뒤)는 로그인부터
            let user = if let u = Auth.auth().currentUser { try await u.reauthenticate(with: credential).user }
                       else { try await Auth.auth().signIn(with: credential).user }
            summary.invalidate()
            pending = Pending(uid: user.uid, revoked: false)
            try await Auth.auth().revokeToken(withAuthorizationCode: code)
            pending = Pending(uid: user.uid, revoked: true)
            await finish(quiet: false)
        } catch {
            // Apple 창을 닫은 것은 실패가 아니다
            phase = (error as? ASAuthorizationError)?.code == .canceled ? before : .failed
        }
    }

    @MainActor private func finish(quiet: Bool) async {
        guard let p = pending else { return }
        if !quiet { phase = .working }
        do {
            _ = try await CrewAPI.call("deleteAccount", [:], as: p.uid)
            await serverDone(p)
        } catch {
            // 재인증한 지 오래됐으면(해제 뒤 한참 지나 재개) Apple 창부터 다시
            if CrewAPI.code(error) == (.failedPrecondition, "reauth") {
                pending = Pending(uid: p.uid, revoked: false)
                phase = .failed
            } else {
                await check(quiet: quiet)
            }
        }
    }

    /// 성공 응답을 받지 못했을 때 서버에 묻는다.
    @MainActor private func check(quiet: Bool) async {
        guard let p = pending else { return }
        if !quiet { phase = .working }
        switch (try? await CrewAPI.call("deletionStatus", ["uid": p.uid]))?["state"] as? String {
        case "deleted": await serverDone(p)
        case "active":
            // 접수되지 않았다. 다시 하려면 Apple 창부터.
            pending = Pending(uid: p.uid, revoked: false)
            phase = .failed
        default:
            // 접수됐으면 서버가 마저 지운다. 확인될 때까지 표시를 남긴다.
            phase = quiet ? .idle : .failed
        }
    }

    @MainActor private func serverDone(_ p: Pending) async {
        var p = p
        p.serverDone = true
        pending = p
        await cleanUp()
    }

    /// 기기 정리. 단계마다 여러 번 해도 된다. 표본 폐기와 크루 캐시 비우기가 모두 성공해야 완료로 알리고,
    /// 하나라도 실패하면 표시를 남기고 실패로 알린다(다음 실행·다시 시도에 반복).
    @MainActor private func cleanUp() async {
        guard let p = pending, p.serverDone else { return }
        phase = .working
        summary.forget(p.uid)
        Crews.forgetLocal(p.uid)
        UserDefaults.standard.removeObject(forKey: Account.readyKey(p.uid))
        try? Auth.auth().signOut()
        let cacheCleared = await crews.forget()
        guard (try? db.dropPendingSamples()) != nil, cacheCleared else {
            phase = .failed
            return
        }
        pending = nil
        phase = .done
    }
}

/// 아무 버튼에서나 Apple 로그인 창을 띄운다(삭제 확인 시트의 버튼은 Apple 버튼 모양이 아니다).
@MainActor private final class AppleAuth: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    /// 창이 떠 있는 동안 자신과 컨트롤러를 붙잡아 둔다(delegate는 약한 참조)
    private var keep: (AppleAuth, ASAuthorizationController)?

    static func authorize(prepare: (ASAuthorizationAppleIDRequest) -> Void) async throws -> ASAuthorization {
        let me = AppleAuth()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        prepare(request)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = me
        controller.presentationContextProvider = me
        me.keep = (me, controller)
        return try await withCheckedThrowingContinuation { me.continuation = $0; controller.performRequests() }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization); continuation = nil; keep = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error); continuation = nil; keep = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
