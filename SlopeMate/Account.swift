import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import Foundation

/// 크루용 계정 (R13, R20). 가입하지 않아도 기록은 모두 쓴다. 서버에는 표시 이름과 만 14세 확인만 둔다(05-design 4장 USER).
@Observable final class Account {
    private(set) var uid: String? = Auth.auth().currentUser?.uid
    private var nonce = ""

    var signedIn: Bool { uid != nil }

    /// 표시 이름: 앞뒤 공백을 빼고 20자까지.
    static func cleanName(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.count > 20 ? nil : t
    }

    /// Apple에 보낼 요청. 이름·이메일은 받지 않는다(표시 이름은 직접 넣음).
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        nonce = UUID().uuidString + UUID().uuidString
        request.requestedScopes = []
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Apple 로그인 결과로 Firebase에 로그인하고 users/{uid}를 만든다. 다시 로그인하면 표시 이름만 바꾼다.
    func complete(_ authorization: ASAuthorization, name: String) async throws {
        guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
              let token = apple.identityToken.flatMap({ String(data: $0, encoding: .utf8) })
        else { throw URLError(.badServerResponse) }
        let credential = OAuthProvider.appleCredential(withIDToken: token, rawNonce: nonce, fullName: nil)
        let user = try await Auth.auth().signIn(with: credential).user
        let doc = Firestore.firestore().collection("users").document(user.uid)
        do {
            if try await doc.getDocument().exists {
                try await doc.updateData(["display_name": name])
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
}
