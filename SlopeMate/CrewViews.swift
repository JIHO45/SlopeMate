import AuthenticationServices
import SwiftUI

/// S11 크루 시작 (확정 v5; R13, R14). 크루가 없을 때 크루 탭 첫 화면.
struct CrewStartView: View {
    var account: Account
    @State private var signUp = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "person.2").font(.title).foregroundStyle(Color.accentText)
                        .frame(width: 64, height: 64).background(Color.surface, in: Circle()).accessibilityHidden(true)
                    Text("친구들과 이번 시즌 기록을 비교해요").font(.title2.bold())
                    Text("크루원끼리 방문일, 하강 횟수, 거리 순위를 봐요.").foregroundStyle(Color.secondaryText)
                    VStack(alignment: .leading, spacing: 14) {
                        Label("보이는 것", systemImage: "eye").font(.subheadline.weight(.semibold))
                        FlowChips(items: ["방문일", "하강 횟수", "거리", "선택한 리조트별 방문일"])
                        Divider()
                        Label("보이지 않는 것", systemImage: "eye.slash").font(.subheadline.weight(.semibold))
                        Text("경로와 위치")
                    }
                    .card(padding: 16)
                    .padding(.top, 8)
                }
                .foregroundStyle(Color.primaryText)
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .safeAreaInset(edge: .bottom) {
                Button { if account.signedIn { /* 크루 만들기 시트: 크루 함수 단계에서 */ } else { signUp = true } } label: {
                    Label("크루 만들기", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 16).padding(.bottom, 12)
                // 링크로 참여: 초대 링크(Universal Links) 단계에서 붙인다
            }
            .background(FadeBackground())
            .navigationTitle("크루")
        }
        .fullScreenCover(isPresented: $signUp) { SignUpView(account: account) }
    }
}

/// 칩 줄: 한 줄 → 3개 + 1개 두 줄 → 세로 (시안은 줄바꿈)
private struct FlowChips: View {
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
                Text("크루원에게 보이는 이름이에요.").font(.subheadline).foregroundStyle(Color.secondaryText).padding(.top, 8)

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
        .alert("Apple 로그인을 마치지 못했어요", isPresented: $failed) {
            Button("확인", role: .cancel) {}
        } message: { Text("인터넷 연결을 확인하고 다시 시도해 주세요.") }
    }

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
                    if case .failure(let e) = result, (e as? ASAuthorizationError)?.code != .canceled { failed = true }
                    return
                }
                busy = true
                Task {
                    do { try await account.complete(auth, name: n); dismiss() } catch { failed = true }
                    busy = false
                }
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .disabled(cleanName == nil || over14 != true || busy)
            .opacity(cleanName == nil || over14 != true ? 0.35 : 1)
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
