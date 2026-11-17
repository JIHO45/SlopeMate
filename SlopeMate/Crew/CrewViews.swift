import AuthenticationServices
import SwiftUI

/// 크루 탭: 가입·크루가 없으면 S11, 있으면 S13. 만들기·링크 참여·가입 시트와 크루 상세 이동을 여기서 모은다.
struct CrewTab: View {
    var account: Account
    var crews: Crews
    var summary: SummarySync
    /// 첫 실행 설정처럼 앱 전체를 덮는 화면이 떠 있는지(그동안 받은 초대는 미뤘다가 연다)
    var covered = false
    @State private var path: [String] = []
    @State private var sheet: CrewSheet?
    @State private var signUp: CrewSheet?
    @State private var afterSignUp: CrewSheet?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                // 받은 목록이 0개일 때만 S11. 처음부터 못 받으면 오류와 다시 시도.
                if !account.signedIn || (crews.status == .ready && crews.ids.isEmpty) {
                    CrewStartView(create: { open(.create) }, join: { open(.link) })
                } else if crews.status == .failed {
                    ContentUnavailableView {
                        Label("크루를 불러오지 못했어요", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("인터넷 연결을 확인하고 다시 시도해 주세요.")
                    } actions: {
                        Button("다시 시도") { crews.retry() }.buttonStyle(.borderedProminent)
                    }
                    .background(FadeBackground())
                    .navigationTitle("크루")
                } else if crews.status == .loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(FadeBackground())
                } else {
                    CrewListView(crews: crews, create: { open(.create) }, join: { open(.link) })
                }
            }
            .navigationDestination(for: String.self) { CrewDetailView(crews: crews, summary: summary, crewId: $0) }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .create:
                CreateCrewSheet(crews: crews) { id in sheet = nil; path = [id] }
            case .link:
                InviteLinkSheet { token in sheet = .invite(token) }
            case .invite(let token):
                JoinCrewSheet(crews: crews, token: token, signedIn: account.signedIn,
                              needSignUp: { sheet = nil; afterSignUp = .invite(token); signUp = .create },
                              opened: { id in sheet = nil; path = [id] })
            }
        }
        .fullScreenCover(item: $signUp, onDismiss: {
            // 가입을 마쳤으면 하려던 일(만들기·참여)을 이어서
            if account.signedIn, let next = afterSignUp { sheet = next }
            afterSignUp = nil
        }) { _ in SignUpView(account: account) }
        // 초대 링크(Universal Links·붙여 넣기): 화면을 실제로 열 수 있을 때 연다. 여러 개가 오면 마지막 것.
        // pendingInvite는 S16이 나타날 때 비운다(가려져서 못 열면 남았다가 가림이 풀릴 때 다시 연다).
        .onChange(of: crews.inviteRequests, initial: true) { openPendingInvite() }
        .onChange(of: covered) { openPendingInvite() }
        .onChange(of: signUp == nil) { openPendingInvite() }
    }

    private func openPendingInvite() {
        guard let t = crews.pendingInvite, !covered, signUp == nil else { return }
        // 이미 그 초대를 보고 있으면 받은 것으로 친다(남겨 두면 닫은 뒤 같은 링크가 무시됨)
        if sheet == .invite(t) { crews.pendingInvite = nil; return }
        // 가입 화면이 끝난 뒤 이어서 할 일도 이 초대로 바꾼다(가입 중에 새 링크가 온 경우)
        afterSignUp = nil
        sheet = .invite(t)
    }

    /// 만들기는 가입이 먼저. 링크 참여는 미리보기까지 가입 없이 보고, 참여할 때 가입한다.
    private func open(_ s: CrewSheet) {
        if s == .create && !account.signedIn { afterSignUp = .create; signUp = .create } else { sheet = s }
    }
}

enum CrewSheet: Identifiable, Equatable {
    case create, link, invite(String)
    var id: String {
        switch self {
        case .create: "create"
        case .link: "link"
        case .invite(let t): "invite-\(t)"
        }
    }
}

/// S11 크루 시작 (확정 v5; R13, R14). 크루가 없을 때 크루 탭 첫 화면.
struct CrewStartView: View {
    var create: () -> Void
    var join: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "person.2").font(.title).foregroundStyle(Color.accentText)
                    .frame(width: 64, height: 64).background(Color.surface, in: Circle()).accessibilityHidden(true)
                Text("친구들과 이번 시즌 기록을 비교해요").font(.title2.bold())
                Text("크루원끼리 방문일, 하강 횟수, 거리 순위를 봐요.").foregroundStyle(Color.secondaryText)
                VisibilityCard().padding(.top, 8)
            }
            .foregroundStyle(Color.primaryText)
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button(action: create) { Label("크루 만들기", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle())
                Button(action: join) {
                    HStack(spacing: 6) {
                        Text("초대 링크가 있나요?").foregroundStyle(Color.secondaryText)
                        Text("링크로 참여 ›").fontWeight(.semibold).foregroundStyle(Color.accentText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .background(FadeBackground())
        .navigationTitle("크루")
    }
}

/// 보이는 것·보이지 않는 것 (S11, S16)
struct VisibilityCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("보이는 것", systemImage: "eye").font(.subheadline.weight(.semibold))
            FlowChips(items: ["방문일", "하강 횟수", "거리", "선택한 리조트별 방문일"])
            Divider()
            Label("보이지 않는 것", systemImage: "eye.slash").font(.subheadline.weight(.semibold))
            Text("경로와 위치")
        }
        .foregroundStyle(Color.primaryText)
        .card(padding: 16)
    }
}

/// 칩 줄: 한 줄 → 3개 + 1개 두 줄 → 세로 (시안은 줄바꿈)
struct FlowChips: View {
    var items: [String]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips(items) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { chips(Array(items.dropLast())) }
                HStack(spacing: 8) { chips(items.suffix(1)) }
            }
            VStack(alignment: .leading, spacing: 8) { chips(items, wrap: true) }
        }
    }
    private func chips(_ list: [String], wrap: Bool = false) -> some View {
        ForEach(list, id: \.self) {
            Text($0).font(.subheadline).fixedSize(horizontal: !wrap, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 4).frame(minHeight: 32)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// S12 가입 (확정 v2, 만 14세 미만 v2; R13, R20). 표시 이름, 만 14세 확인, Apple로 계속하기.
struct SignUpView: View {
    var account: Account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var over14: Bool?
    @State private var busy = false
    @State private var failed = false
    @State private var refused = false
    @State private var banned = false
    /// 서버에 미리 물은 결과(R16): false면 금지어. nil은 아직 모름·묻지 못함(가입할 때 서버가 다시 본다).
    @State private var nameOK: Bool?
    @State private var checking = false
    @State private var restricted = false

    private var cleanName: String? { Account.cleanName(name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .frame(width: 44, height: 44).glassCircle()
                }
                .buttonStyle(.plain).accessibilityLabel("닫기")
                .padding(.bottom, 16)

                Text("크루 가입").font(.title.bold()).accessibilityAddTraits(.isHeader)
                Text("크루를 쓰려면 계정이 필요해요. 기록은 가입 없이도 모두 쓸 수 있어요.")
                    .foregroundStyle(Color.secondaryText).padding(.top, 8)

                Text("표시 이름").font(.subheadline.weight(.semibold)).padding(.top, 24).padding(.bottom, 8)
                TextField("표시 이름", text: $name)
                    .textContentType(.nickname)
                    .onChange(of: name) { if name.count > 20 { name = String(name.prefix(20)) } }
                    .padding(.horizontal, 16).frame(minHeight: 52)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.cardBorder))
                    .accessibilityHint("크루원에게 보이는 이름이에요.")
                if nameOK == false {
                    Label("쓸 수 없는 단어가 있어요", systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(Color(light: 0x8A1C1C, dark: 0xFF8A80)).padding(.top, 8)
                } else {
                    Text("크루원에게 보이는 이름이에요.").font(.subheadline).foregroundStyle(Color.secondaryText).padding(.top, 8)
                }

                Text("나이").font(.subheadline.weight(.semibold)).padding(.top, 24).padding(.bottom, 8)
                VStack(spacing: 8) {
                    ageRow("만 14세 이상이에요", value: true)
                    ageRow("만 14세 미만이에요", value: false)
                }
                if over14 == false {
                    Label { Text("크루는 만 14세부터 쓸 수 있어요. 기록은 계속 쓸 수 있어요") } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(light: 0xA87400, dark: 0xF2C14E))
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.cardBorder))
                    .padding(.top, 12)
                }
            }
            .foregroundStyle(Color.primaryText)
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .safeAreaInset(edge: .bottom) { bottom.padding(.horizontal, 16).padding(.bottom, 12).background(Color.bg) }
        .background(Color.bg.ignoresSafeArea())
        // 입력을 멈추면 서버에 미리 묻는다(금지어면 Apple 로그인 전에 알림)
        .task(id: cleanName) {
            nameOK = nil
            guard let n = cleanName else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            checking = true
            let ok = await Account.checkName(n)
            checking = false
            if !Task.isCancelled { nameOK = ok }
        }
        .alert(banned ? "쓸 수 없는 단어가 있어요" : "Apple 로그인을 마치지 못했어요", isPresented: $failed) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(banned ? "표시 이름을 바꿔 다시 시도해 주세요."
                 : refused ? "이 계정으로는 지금 가입할 수 없어요. 계정 삭제가 진행 중이면 끝난 뒤 다시 가입해 주세요."
                 : "인터넷 연결을 확인하고 다시 시도해 주세요.")
        }
        .alert("이 계정은 크루 기능을 쓸 수 없어요", isPresented: $restricted) {
            Button("확인") { dismiss() }
        } message: {
            Text("신고 처리로 이용이 제한된 계정이에요. 크루 나가기와 계정 삭제는 할 수 있어요.")
        }
    }

    /// 이름이 있고, 만 14세 이상이고, 금지어로 확인되지 않았고, 확인 중이 아닐 때
    private var canSignIn: Bool { cleanName != nil && over14 == true && nameOK != false && !checking }

    /// 만 14세 미만이면 Apple 버튼을 끄고 아래에 돌아가기 (만 14세 미만 v2)
    private var bottom: some View {
        VStack(spacing: 12) {
            if over14 != false {
                Label("서버에는 이번 시즌 합계(방문일·하강 횟수·거리)와 리조트별 방문일만 보내요. 경로와 위치는 보내지 않아요.", systemImage: "lock")
                    .font(.subheadline).foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SignInWithAppleButton(.continue, onRequest: account.prepare) { result in
                guard case .success(let auth) = result, let n = cleanName else {
                    // 사용자가 취소한 경우는 조용히 둔다
                    if case .failure(let e) = result, (e as? ASAuthorizationError)?.code != .canceled { refused = false; banned = false; failed = true }
                    return
                }
                busy = true
                Task {
                    do {
                        if try await account.complete(auth, name: n) { restricted = true } else { dismiss() }
                    } catch {
                        banned = Account.isBannedName(error)
                        if banned { nameOK = false }
                        refused = Account.isRefusal(error)
                        failed = true
                    }
                    busy = false
                }
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .disabled(!canSignIn || busy)
            .opacity(canSignIn ? 1 : 0.35)
            .overlay { if busy { ProgressView() } }
            if over14 == false {
                Button("돌아가기") { dismiss() }
                    .font(.headline).foregroundStyle(Color.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
            }
        }
    }

    private func ageRow(_ title: String, value: Bool) -> some View {
        let on = over14 == value
        return Button { over14 = value } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").font(.title3)
                    .foregroundStyle(on ? Color.accentFill : Color.secondaryText)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).frame(minHeight: 56)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(on ? Color.accentFill : Color.cardBorder, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}
