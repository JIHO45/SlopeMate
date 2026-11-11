import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation

/// 크루용 계정 (R13, R20). 가입하지 않아도 기록은 모두 쓴다. 서버에는 표시 이름과 만 14세 확인만 둔다(05-design 4장 USER).
/// Firebase 로그인과 가입 완료(계정 문서)를 구분한다. `uid`는 가입을 마친 계정만이고, 크루 구독·합계 동기화·설정의 계정 칸이 이것을 따른다.
@Observable final class Account {
    /// 가입을 마친 계정
    private(set) var uid: String?
    private var nonce = ""
    @ObservationIgnored private var listener: AuthStateDidChangeListenerHandle?
    /// 가입·계정 삭제가 로그인을 다루는 동안에는 가입 확인(로그인만 있고 계정 문서가 없으면 로그아웃)을 멈춘다
    @ObservationIgnored var holdCheck = false

    var signedIn: Bool { uid != nil }

    /// 로그인 상태가 바뀌면(로그아웃, 서버에서 사용자 삭제·토큰 무효) 바로 따라간다.
    init() {
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in self?.authChanged(user?.uid) }
    }

    static func readyKey(_ uid: String) -> String { "profileReady-\(uid)" }

    /// 가입을 마친 로그인만 계정으로 본다. 기기에 가입 완료 표시가 없으면(가입 도중 앱이 꺼짐, 다른 기기에서 가입)
    /// 계정 문서를 한 번 읽어 정한다: 있으면 완료, 없으면 로그아웃(가입 화면부터 다시), 삭제 중이면 삭제 흐름에 맡긴다.
    private func authChanged(_ id: String?) {
        guard let id else { uid = nil; return }
        if UserDefaults.standard.bool(forKey: Self.readyKey(id)) { uid = id; return }
        uid = nil
        guard !holdCheck else { return }
        Task { await verify(id) }
    }

    /// 앱을 다시 볼 때 확인하지 못한 로그인(오프라인이었음)을 다시 본다
    func recheck() {
        if uid == nil, !holdCheck, let id = Auth.auth().currentUser?.uid { Task { await verify(id) } }
    }

    @MainActor private func verify(_ id: String) async {
        guard let doc = try? await Firestore.firestore().collection("users").document(id).getDocument(),
              !holdCheck, Auth.auth().currentUser?.uid == id else { return }
        if !doc.exists {
            try? Auth.auth().signOut()
        } else if doc.get("deleting") as? Bool != true {
            UserDefaults.standard.set(true, forKey: Self.readyKey(id))
            uid = id
        }
    }

    /// 표시 이름: 앞뒤 공백을 빼고 20자까지. 서버(함수 [...t].length, 규칙 size())와 같게 유니코드 문자 단위로 센다.
    static func cleanName(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.unicodeScalars.count > 20 ? nil : t
    }

    /// Apple에 보낼 요청. 이름·이메일은 받지 않는다(표시 이름은 직접 넣음).
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        nonce = UUID().uuidString + UUID().uuidString
        request.requestedScopes = []
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Apple 로그인 결과로 Firebase에 로그인하고 signUp 함수로 계정 문서를 만든다(금지어·만 14세 확인·삭제 표시는 서버가 본다).
    /// 다시 로그인하면 표시 이름만 바뀌고 속한 크루의 이름도 함께 바뀐다. 이용 제한 계정은 이름을 바꾸지 않고 restricted를 돌려준다.
    /// 실패하면 로그아웃해 가입 화면에서 이름을 고쳐 다시 할 수 있게 한다.
    @discardableResult
    func complete(_ authorization: ASAuthorization, name: String) async throws -> Bool {
        holdCheck = true
        defer { holdCheck = false }
        let user = try await Auth.auth().signIn(with: try credential(authorization).credential).user
        do {
            let r = try await CrewAPI.call("signUp", ["name": name, "age14Confirmed": true])
            UserDefaults.standard.set(true, forKey: Self.readyKey(user.uid))
            uid = user.uid
            return r["restricted"] as? Bool ?? false
        } catch {
            try? Auth.auth().signOut()
            throw error
        }
    }

    /// 금지어·사칭으로 거절된 이름(R16): "쓸 수 없는 단어가 있어요"
    static func isBannedName(_ error: Error) -> Bool { CrewAPI.code(error) == (.invalidArgument, "banned") }

    /// 이름을 쓸 수 있는지 서버에 미리 묻는다(로그인 없이, 안내용). 묻지 못하면 nil(가입할 때 서버가 다시 본다).
    static func checkName(_ name: String) async -> Bool? {
        do { _ = try await CrewAPI.call("checkName", ["name": name]); return true } catch {
            return isBannedName(error) ? false : nil
        }
    }

    /// Apple 로그인 결과 → Firebase 자격 증명과 인증 코드(연결 해제에 바로 쓴다, 5분 유효·한 번만).
    func credential(_ authorization: ASAuthorization) throws -> (credential: AuthCredential, code: String) {
        guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
              let token = apple.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
              let code = apple.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) })
        else { throw URLError(.badServerResponse) }
        return (OAuthProvider.appleCredential(withIDToken: token, rawNonce: nonce, fullName: nil), code)
    }

    /// 다시 시도해도 안 되는 거절(삭제 중인 계정, 형식)인지. 그 밖은 연결 문제로 본다.
    static func isRefusal(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == FirestoreErrorDomain { return e.code == FirestoreErrorCode.permissionDenied.rawValue }
        if e.domain == FunctionsErrorDomain {
            return [FunctionsErrorCode.permissionDenied, .invalidArgument].map(\.rawValue).contains(e.code)
        }
        return false
    }
}

/// 크루 함수 호출 (서울 리전 Callable). 경합으로 끝난 aborted만 몇 번 다시 부른다.
enum CrewAPI {
    /// `as`를 주면 보낼 때마다 로그인 계정이 그 uid인지 확인한다(계정이 바뀌거나 지워진 뒤 늦게 나가는 요청을 막음).
    static func call(_ name: String, _ data: [String: Any], as uid: String? = nil) async throws -> [String: Any] {
        let fn = Functions.functions(region: "asia-northeast3").httpsCallable(name)
        var attempt = 0
        while true {
            if let uid, Auth.auth().currentUser?.uid != uid { throw CancellationError() }
            do {
                return try await fn.call(data).data as? [String: Any] ?? [:]
            } catch let e as NSError where e.domain == FunctionsErrorDomain
                        && e.code == FunctionsErrorCode.aborted.rawValue && attempt < 3 {
                attempt += 1
                try await Task.sleep(for: .milliseconds(200 * attempt + Int.random(in: 0...200)))
            }
        }
    }

    /// 서버가 돌려준 오류 코드와 메시지("full", "owned-limit", "kicked" 등)
    static func code(_ error: Error) -> (FunctionsErrorCode?, String) {
        let e = error as NSError
        guard e.domain == FunctionsErrorDomain else { return (nil, "") }
        return (FunctionsErrorCode(rawValue: e.code), e.localizedDescription)
    }
}
