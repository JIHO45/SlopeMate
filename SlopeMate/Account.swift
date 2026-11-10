import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation

/// 크루용 계정 (R13, R20). 가입하지 않아도 기록은 모두 쓴다. 서버에는 표시 이름과 만 14세 확인만 둔다(05-design 4장 USER).
@Observable final class Account {
    private(set) var uid: String?
    private var nonce = ""
    @ObservationIgnored private var listener: AuthStateDidChangeListenerHandle?

    var signedIn: Bool { uid != nil }

    /// 로그인 상태가 바뀌면(로그아웃, 서버에서 사용자 삭제·토큰 무효) 바로 따라간다.
    init() {
        uid = Auth.auth().currentUser?.uid
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in self?.uid = user?.uid }
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

    /// Apple 로그인 결과로 Firebase에 로그인하고 users/{uid}를 만든다.
    /// 다시 로그인하면 표시 이름만 바꾸고, 속한 크루의 이름도 함께 바뀐다(setDisplayName 함수).
    func complete(_ authorization: ASAuthorization, name: String) async throws {
        let user = try await Auth.auth().signIn(with: try credential(authorization).credential).user
        let doc = Firestore.firestore().collection("users").document(user.uid)
        do {
            if try await doc.getDocument().exists {
                _ = try await CrewAPI.call("setDisplayName", ["name": name])
            } else {
                try await doc.setData(["display_name": name, "age14_confirmed": true, "deleting": false,
                                       "created_at": FieldValue.serverTimestamp()])
            }
        } catch {
            // 계정 문서 없이 로그인 상태로 남지 않게 한다. 다시 시도하면 처음부터.
            try? Auth.auth().signOut()
            throw error
        }
        uid = user.uid
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
