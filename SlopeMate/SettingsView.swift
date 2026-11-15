import SwiftUI
import UserNotifications

/// S17 설정 (확정 v3, 지도 데이터 출처 v2; R9, R11, R12, R13, R19). 계정 칸은 로그인했을 때만 보인다.
struct SettingsView: View {
    let db: AppDatabase
    /// 홈 리조트·시즌권을 바꿨을 수 있으니 홈이 다시 읽도록 알린다
    var changed: () -> Void = {}
    @State private var homes: [String] = []
    @State private var passCount = 0
    @State private var snowPrompt = Settings.snowPromptOn
    @State private var consent = Settings.consentSince != nil
    @State private var editingHomes = false
    @State private var welcome = false
    @State private var notify: UNAuthorizationStatus?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var error: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(AccountDeletion.self) private var deletion
    @Environment(Crews.self) private var crews

    /// 아직 정하지 않았으면 행을 숨긴다(빈 링크를 내보내지 않음)
    static let privacyPolicyURL: URL? = URL(string: "https://slopemate-f9a5b.web.app/privacy")
    static let contactEmail: String? = "joe45dev@gmail.com"

    var body: some View {
        List {
            Section("기록") {
                Button { editingHomes = true } label: {
                    row("홈 리조트", value: homesText, chevron: true)
                }
                NavigationLink {
                    SeasonPassListView(db: db, season: HomeData.currentSeason())
                } label: {
                    row("시즌권", value: passCount == 0 ? "없음" : "\(passCount)장")
                }
                // R49: 알림 카드에서 "괜찮아요"를 눌렀어도 여기서 다시 켠다. 한 번 물었으면 iOS 설정으로
                Button(action: notificationsTapped) {
                    row("종료 잊음 알림", value: notify.map { $0 == .authorized || $0 == .provisional ? "켜짐" : "꺼짐" }, chevron: true)
                }
            }
            .listRowBackground(Color.card)
            Section {
                Toggle("설질 질문 표시", isOn: $snowPrompt)
                    .onChange(of: snowPrompt) { _, on in Settings.snowPromptOn = on }
                Toggle("설질·대기 시간 익명으로 보내기", isOn: $consent)
                    .onChange(of: consent) { _, on in
                        do {
                            Settings.consentAsked = true
                            try Settings.setConsent(on, db: db)
                        } catch { self.error = error.localizedDescription }
                    }
            } header: {
                Text("설질")
            } footer: {
                Text("리조트, 슬로프·리프트, 15분 시간대, 설질·대기 시간만 보내요. 계정, 기기 정보, GPS 좌표와 이동 경로는 보내지 않아요.")
                    .foregroundStyle(Color.secondaryText)
            }
            .listRowBackground(Color.card)
            Section("정보") {
                if let url = Self.privacyPolicyURL {
                    Link(destination: url) { row("개인정보처리방침", icon: "arrow.up.right") }
                }
                NavigationLink { MapSourceView() } label: { row("지도 데이터 출처", value: "OpenStreetMap, Copernicus") }
                Button { welcome = true } label: { row("처음 안내 다시 보기", chevron: true) }
                if let mail = Self.contactEmail, let url = URL(string: "mailto:\(mail)") {
                    Link(destination: url) { row("문의", icon: "arrow.up.right") }
                }
                row("버전", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
            .listRowBackground(Color.card)
            if deletion.account.signedIn {
                Section {
                    NavigationLink { BlockedListView(crews: crews) } label: {
                        row("차단한 크루원", value: crews.blocked.isEmpty ? "없음" : "\(crews.blocked.count)명")
                    }
                    Button("계정 삭제") { deletion.phase = .confirm }.foregroundStyle(AccountDeleteSheet.dangerText)
                } header: {
                    Text("계정")
                } footer: {
                    Text("계정, 활동 합계, 크루 소속이 지워져요. 기기의 기록은 남아요.").foregroundStyle(Color.secondaryText)
                }
                .listRowBackground(Color.card)
            }
        }
        .tint(Color.accentFill)
        .scrollContentBackground(.hidden)
        .background(Color.bg)
        .foregroundStyle(Color.primaryText)
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear(perform: reload)
        // iOS 설정에서 알림을 바꾸고 돌아오면 줄 값을 다시 읽는다
        .onChange(of: phase) { if phase == .active { Task { notify = await ForgottenStop.status() } } }
        // 홈 리조트·시즌권을 바꿨을 수 있으니 설정을 떠나면(시즌권 화면으로 들어갈 때 포함) 홈이 다시 읽는다
        .onDisappear(perform: changed)
        // R51: O1 설명만 다시. 홈 리조트·동의·완료 상태는 그대로, 권한도 묻지 않는다
        .fullScreenCover(isPresented: $welcome) { WelcomeView(revisit: true) { welcome = false } }
        .fullScreenCover(isPresented: $editingHomes, onDismiss: reload) {
            HomeSetupView(db: db, cancel: { editingHomes = false }) { editingHomes = false }
        }
        .alert("설정을 바꾸지 못했어요", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("확인") {}
        } message: { Text(error ?? "") }
    }

    private var homesText: String {
        guard let first = homes.first else { return "없음" }
        return homes.count == 1 ? Resort.name(first) : "\(Resort.name(first)) 외 \(homes.count - 1)곳"
    }

    private func notificationsTapped() {
        if notify == .notDetermined {
            Task { await ForgottenStop.request(); notify = await ForgottenStop.status() }
        } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            openURL(url)
        }
    }

    private func reload() {
        Task { notify = await ForgottenStop.status() }
        homes = (try? db.homeResorts()) ?? []
        passCount = ((try? db.passes(season: HomeData.currentSeason())) ?? []).count
    }

    private func row(_ title: String, value: String? = nil, icon: String? = nil, chevron: Bool = false) -> some View {
        // 아주 큰 글씨에서는 이름 아래에 값을 둔다
        HStack {
            let text = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
            text {
                Text(title).foregroundStyle(Color.primaryText)
                if !typeSize.isAccessibilitySize { Spacer() }
                if let value { Text(value).foregroundStyle(Color.secondaryText) }
            }
            if typeSize.isAccessibilitySize { Spacer() }
            if let icon { Image(systemName: icon).font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText) }
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }
}

/// S17 지도 데이터 출처 (v3). OSM 저작권 표시와 ODbL, Copernicus DEM 출처·면책 문장(라이선스 6조).
struct MapSourceView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("슬로프와 리프트 지도는 OpenStreetMap 데이터로 만들었어요.")
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.body.weight(.semibold)).foregroundStyle(Color.accentText)
                    Link("라이선스: Open Database License (ODbL)", destination: URL(string: "https://opendatacommons.org/licenses/odbl/")!)
                        .font(.subheadline).foregroundStyle(Color.secondaryText)
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.card)
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("지형(음영·등고선)은 Copernicus DEM으로 만들었어요.")
                    Text(Terrain.source).font(.subheadline.weight(.semibold))
                    Text("Copernicus WorldDEM-30으로 만들었습니다 © DLR e.V. 2010-2014, © Airbus Defence and Space GmbH 2014-2018, Copernicus 프로그램(유럽연합·ESA) 제공; 모든 권리 보유")
                        .font(.subheadline).foregroundStyle(Color.secondaryText)
                    Text(Terrain.disclaimer).font(.subheadline.weight(.semibold))
                    Text("법률 또는 위임에 따라 Copernicus 프로그램을 맡은 기관은 Copernicus WorldDEM-30의 어떤 사용에 대해서도 책임을 지지 않습니다")
                        .font(.subheadline).foregroundStyle(Color.secondaryText)
                    Link("라이선스: Copernicus DEM GLO-30", destination: Terrain.licenseURL)
                        .font(.subheadline).foregroundStyle(Color.secondaryText)
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.card)
        }
        .scrollContentBackground(.hidden)
        .background(Color.bg)
        .foregroundStyle(Color.primaryText)
        .navigationTitle("지도 데이터 출처")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

/// S17 계정 삭제 확인·완료·실패 (확정 v3; R13, R21). 진행 중에는 같은 내용에 버튼만 잠근다.
struct AccountDeleteSheet: View {
    var deletion: AccountDeletion
    /// 진행 중일 때 계속 보여 줄 직전 화면
    @State private var shown = AccountDeletion.Phase.confirm

    static let dangerText = Color(light: 0x8A1C1C, dark: 0xFFB4B4)
    private static let dangerFill = Color(light: 0xFDE8E8, dark: 0x4A1F22)
    private static let warning = Color(light: 0xA87400, dark: 0xF2B92E)

    var body: some View {
        let busy = deletion.phase == .working
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch shown {
                case .done:
                    icon("checkmark", .accentText)
                    title("계정을 삭제했어요")
                    note("기기의 기록은 그대로 남아 있어요. 크루를 다시 쓰려면 새로 가입해야 해요.")
                    button("확인", fill: .accentFill, text: .onAccent) { deletion.close() }.padding(.top, 8)
                case .failed:
                    icon("exclamationmark.triangle", Self.warning)
                    title("계정을 삭제하지 못했어요")
                    note("인터넷 연결을 확인하고 다시 시도해 주세요. 계속 안 되면 문의해 주세요.")
                    VStack(spacing: 8) {
                        button("다시 시도", fill: .accentFill, text: .onAccent) { Task { await deletion.proceed() } }
                        if let mail = SettingsView.contactEmail, let url = URL(string: "mailto:\(mail)") {
                            Link(destination: url) { label("문의하기", fill: Color.primaryText.opacity(0.08), text: .primaryText) }
                        }
                        Button("닫기") { deletion.close() }
                            .font(.headline).foregroundStyle(Color.primaryText).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .padding(.top, 8)
                default:
                    icon("person.fill.xmark", .accentText)
                    title("계정을 삭제할까요?")
                    note("다음 항목이 지워져요.")
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(["계정", "이번 시즌 활동 합계(서버)", "크루 소속", "Apple 로그인 연결"], id: \.self) { item in
                            HStack(spacing: 10) {
                                Circle().fill(Self.dangerText).frame(width: 6, height: 6).accessibilityHidden(true)
                                Text(item)
                            }
                        }
                    }
                    .font(.subheadline)
                    .card(padding: 14)
                    Text("기기의 기록은 그대로 남아요.").font(.subheadline)
                    VStack(spacing: 8) {
                        button("계정 삭제", fill: Self.dangerFill, text: Self.dangerText) { Task { await deletion.proceed() } }
                        button("취소", fill: Color.primaryText.opacity(0.08), text: .primaryText) { deletion.close() }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 16)
            .disabled(busy)
        }
        .overlay { if busy { ProgressView().controlSize(.large) } }
        .foregroundStyle(Color.primaryText)
        .background(Color.bg)
        .presentationDetents(shown == .confirm ? [.large] : [.medium, .large])
        .interactiveDismissDisabled(busy)
        .onChange(of: deletion.phase, initial: true) { _, p in if p != .working && p != .idle { shown = p } }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.title2).foregroundStyle(color)
            .frame(width: 56, height: 56).background(Color.surface, in: Circle()).accessibilityHidden(true)
    }
    private func title(_ t: String) -> some View { Text(t).font(.title2.bold()).accessibilityAddTraits(.isHeader) }
    private func note(_ t: String) -> some View { Text(t).font(.subheadline).foregroundStyle(Color.secondaryText) }
    private func label(_ t: String, fill: Color, text: Color) -> some View {
        Text(t).font(.headline).foregroundStyle(text)
            .padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 52).background(fill, in: Capsule())
    }
    private func button(_ t: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { label(t, fill: fill, text: text) }.buttonStyle(.plain)
    }
}
