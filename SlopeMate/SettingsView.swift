import SwiftUI

/// S17 설정 (확정 v3 로그인 안 함, 지도 데이터 출처 v2; R9, R11, R12, R19). 계정 칸은 서버 기능(로그인)과 함께 붙인다.
struct SettingsView: View {
    let db: AppDatabase
    /// 홈 리조트·시즌권을 바꿨을 수 있으니 홈이 다시 읽도록 알린다
    var changed: () -> Void = {}
    @State private var homes: [String] = []
    @State private var passCount = 0
    @State private var snowPrompt = Settings.snowPromptOn
    @State private var consent = Settings.consentSince != nil
    @State private var editingHomes = false
    @State private var error: String?

    /// 아직 정하지 않았으면 행을 숨긴다(빈 링크를 내보내지 않음)
    static let privacyPolicyURL: URL? = nil
    static let contactEmail: String? = nil

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
                NavigationLink { MapSourceView() } label: { row("지도 데이터 출처", value: "OpenStreetMap") }
                if let mail = Self.contactEmail, let url = URL(string: "mailto:\(mail)") {
                    Link(destination: url) { row("문의", icon: "arrow.up.right") }
                }
                row("버전", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
            .listRowBackground(Color.card)
        }
        .tint(Color.accentFill)
        .scrollContentBackground(.hidden)
        .background(Color.bg)
        .foregroundStyle(Color.primaryText)
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear(perform: reload)
        // 홈 리조트·시즌권을 바꿨을 수 있으니 설정을 떠나면(시즌권 화면으로 들어갈 때 포함) 홈이 다시 읽는다
        .onDisappear(perform: changed)
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

    private func reload() {
        homes = (try? db.homeResorts()) ?? []
        passCount = ((try? db.passes(season: HomeData.currentSeason())) ?? []).count
    }

    private func row(_ title: String, value: String? = nil, icon: String? = nil, chevron: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.primaryText)
            Spacer()
            if let value { Text(value).foregroundStyle(Color.secondaryText) }
            if let icon { Image(systemName: icon).font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText) }
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }
}

/// S17 지도 데이터 출처 (v2). OSM 저작권 표시와 ODbL.
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
        }
        .scrollContentBackground(.hidden)
        .background(Color.bg)
        .foregroundStyle(Color.primaryText)
        .navigationTitle("지도 데이터 출처")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}
