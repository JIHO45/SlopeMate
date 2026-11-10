import Testing
@testable import SlopeMate

struct AccountTests {
    @Test func displayName() {
        #expect(Account.cleanName("  지호 ") == "지호")
        #expect(Account.cleanName("   ") == nil)
        #expect(Account.cleanName(String(repeating: "가", count: 20)) != nil)
        #expect(Account.cleanName(String(repeating: "가", count: 21)) == nil)
    }

    /// 계정 삭제 재개(R13): 앱이 어느 단계에서 꺼졌든 다음에 할 일이 정해진다. 로그아웃만으로 완료로 보지 않는다.
    @Test func deletionNextStep() {
        typealias D = AccountDeletion
        #expect(D.next(nil, signedIn: "a") == .none)
        // 재인증 직후·Apple 해제 직후 종료(해제 여부 모름): 로그인 여부와 관계없이 Apple 창부터 다시
        #expect(D.next(.init(uid: "a", revoked: false), signedIn: "a") == .reauth)
        #expect(D.next(.init(uid: "a", revoked: false), signedIn: nil) == .reauth)
        // 해제는 끝났고 서버 응답을 못 받음: 서버만 다시
        #expect(D.next(.init(uid: "a", revoked: true), signedIn: "a") == .callServer)
        // 로그아웃됐거나 다른 계정: 서버에 상태를 묻는다
        #expect(D.next(.init(uid: "a", revoked: true), signedIn: nil) == .checkStatus)
        #expect(D.next(.init(uid: "a", revoked: true), signedIn: "b") == .checkStatus)
        // 서버 삭제는 끝났고 기기 정리(표본 버리기 등)가 남음: 로그인 여부와 관계없이 정리만 다시
        #expect(D.next(.init(uid: "a", revoked: true, serverDone: true), signedIn: nil) == .cleanUp)
        #expect(D.next(.init(uid: "a", revoked: true, serverDone: true), signedIn: "a") == .cleanUp)
    }

    /// 크루 캐시 비우기가 끝나지 않았으면 로그아웃 상태(uid가 그대로 nil)로 다시 켜도 다시 시도한다.
    @Test func crewCachePurgeRetriesWhileSignedOut() {
        #expect(Crews.needsFollow(nil, current: nil, purgePending: true))
        #expect(!Crews.needsFollow(nil, current: nil, purgePending: false))
        #expect(Crews.needsFollow("a", current: nil, purgePending: false))
    }
}
