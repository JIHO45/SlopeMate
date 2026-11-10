import FirebaseFirestore
import FirebaseFunctions
import SwiftUI

// 크루 화면 S13~S16과 크루 만들기 (확정: S13 v3, 크루 만들기 v1, S14 v2, S15 v1·v2·나가기 확인 v2, S16 v2·무효·정원 초과 v2; R14).
// 바꾸는 일은 모두 서버 함수(CrewAPI)로 하고, 화면은 Crews의 실시간 구독을 그대로 보여 준다.

private let failMessage = "처리하지 못했어요. 인터넷 연결을 확인하고 다시 시도해 주세요."

/// 크루 아이콘 원
private struct CrewIcon: View {
    var size: CGFloat = 44
    var symbol = "person.2"
    var body: some View {
        Image(systemName: symbol).font(size > 50 ? .title : .body).foregroundStyle(Color.accentText)
            .frame(width: size, height: size).background(Color.surface, in: Circle()).accessibilityHidden(true)
    }
}

// MARK: S13 내 크루 목록

struct CrewListView: View {
    var crews: Crews
    var create: () -> Void
    var join: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if crews.hasProblem {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(light: 0xA87400, dark: 0xF2C14E))
                        Text("크루 정보를 새로 받지 못했어요").font(.subheadline)
                        Spacer(minLength: 0)
                        Button("다시 시도") { crews.retry() }.font(.subheadline.weight(.semibold))
                    }
                    .card(padding: 14)
                }
                VStack(spacing: 0) {
                    ForEach(crews.ids, id: \.self) { id in
                        if let c = crews.crew(id) {
                            NavigationLink(value: c.id) { row(c) }.buttonStyle(.plain)
                        } else {
                            HStack(spacing: 14) {
                                CrewIcon()
                                if crews.failedCrews.contains(id) {
                                    Text("이 크루를 불러오지 못했어요").foregroundStyle(Color.secondaryText)
                                } else {
                                    ProgressView()
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 72)
                        }
                        if id != crews.ids.last { Divider() }
                    }
                }
                .padding(.horizontal, 16)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
                Text("크루장인 크루 \(crews.ownedCount)/\(Crews.maxOwned)")
                    .font(.subheadline).foregroundStyle(Color.secondaryText).padding(.horizontal, 4)
            }
            .padding(.horizontal, 16).padding(.top, 12)
        }
        .background(FadeBackground())
        .navigationTitle("크루")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: create) { Label("크루 만들기", systemImage: "plus") }
                    Button(action: join) { Label("초대 링크로 참여", systemImage: "link") }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("크루 추가")
            }
        }
    }

    private func row(_ c: Crews.Crew) -> some View {
        HStack(spacing: 14) {
            CrewIcon()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(c.name).font(.headline)
                    if c.ownerUid == crews.uid {
                        Text("크루장").font(.footnote).foregroundStyle(Color.secondaryText)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.cardBorder))
                    }
                }
                Text(c.memberCount <= 1 ? "1명 · 크루원을 모아 보세요"
                     : "\(c.memberCount)명" + (crews.myVisitRank(c.id).map { " · 방문일 \($0)위" } ?? ""))
                    .font(.subheadline).foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
        }
        .foregroundStyle(Color.primaryText)
        .frame(minHeight: 72)
        .contentShape(Rectangle())
    }
}

// MARK: 크루 만들기

struct CreateCrewSheet: View {
    var crews: Crews
    var created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var limitHit = false
    @State private var failed = false

    private var clean: String? { Account.cleanName(name) }
    private var atLimit: Bool { limitHit || crews.ownedCount >= Crews.maxOwned }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("크루 이름").font(.subheadline.weight(.semibold))
                        TextField("예: 하이원 주말팀", text: $name)
                            .onChange(of: name) { if name.unicodeScalars.count > 20 { name = String(name.prefix(20)) } }
                            .padding(.horizontal, 16).frame(minHeight: 52)
                            .background(Color.card, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.cardBorder))
                        Text("\(name.trimmingCharacters(in: .whitespaces).unicodeScalars.count)/20")
                            .font(.subheadline).monospacedDigit().foregroundStyle(Color.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Text("크루장인 크루 \(crews.ownedCount)/\(Crews.maxOwned) · 크루원은 최대 \(Crews.maxMembers)명")
                        .font(.subheadline).foregroundStyle(Color.secondaryText)
                    if atLimit {
                        Label("이미 5개 이상의 크루에서 크루장을 맡고 있어요", systemImage: "exclamationmark.triangle")
                            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).card(padding: 14)
                    }
                    Label("크루원에게 이번 시즌 방문일·하강 횟수·거리와 선택한 리조트별 방문일이 보여요. 경로와 위치는 보이지 않아요.",
                          systemImage: "eye")
                        .font(.subheadline).card(padding: 16)
                    Text("초대 링크를 받은 사람은 가입 전에도 크루 이름·인원과 크루장 표시 이름을 볼 수 있어요.")
                        .font(.subheadline).foregroundStyle(Color.secondaryText)
                }
                .foregroundStyle(Color.primaryText)
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button("만들기") { Task { await make() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(clean == nil || atLimit || busy)
                        .opacity(clean == nil || atLimit ? 0.4 : 1)
                        .overlay { if busy { ProgressView() } }
                    Button("취소") { dismiss() }.font(.headline).foregroundStyle(Color.primaryText).frame(minHeight: 52)
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .background(Color.bg.ignoresSafeArea())
            .navigationTitle("크루 만들기").navigationBarTitleDisplayMode(.inline)
            .alert("크루를 만들지 못했어요", isPresented: $failed) { Button("확인", role: .cancel) {} } message: { Text(failMessage) }
        }
        .presentationDetents([.large])
    }

    private func make() async {
        guard let n = clean else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await CrewAPI.call("createCrew", ["name": n])
            if let id = r["crewId"] as? String { created(id) }
        } catch {
            if CrewAPI.code(error).0 == .resourceExhausted { limitHit = true } else { failed = true }
        }
    }
}

// MARK: 초대 링크 붙여 넣기 (Universal Links 전까지 S13·S11의 "링크로 참여")

struct InviteLinkSheet: View {
    var found: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var wrong = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("받은 초대 링크를 붙여 넣어 주세요.").foregroundStyle(Color.secondaryText)
                TextField("https://…", text: $text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .padding(.horizontal, 16).frame(minHeight: 52)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.cardBorder))
                PasteButton(payloadType: String.self) { items in
                    if let s = items.first { text = s; submit() }
                }
                if wrong { Text("초대 링크를 확인해 주세요").font(.subheadline).foregroundStyle(Color.stopRed) }
                Spacer()
                Button("확인", action: submit).buttonStyle(PrimaryButtonStyle()).disabled(text.isEmpty).opacity(text.isEmpty ? 0.4 : 1)
            }
            .foregroundStyle(Color.primaryText)
            .padding(16)
            .background(Color.bg.ignoresSafeArea())
            .navigationTitle("초대 링크로 참여").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        if let t = Crews.token(from: text) { found(t) } else { wrong = true }
    }
}

// MARK: S16 초대 링크로 참여

struct JoinCrewSheet: View {
    var crews: Crews
    var token: String
    var signedIn: Bool
    var needSignUp: () -> Void
    var opened: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Preview { var name: String; var count: Int; var owner: String; var full: Bool; var member: Bool }
    private enum State { case loading, ready(Preview), invalid, failed }
    @SwiftUI.State private var state = State.loading
    @SwiftUI.State private var busy = false
    @SwiftUI.State private var kicked = false
    @SwiftUI.State private var failed = false

    var body: some View {
        VStack(spacing: 16) {
            switch state {
            case .loading:
                ProgressView().frame(maxHeight: .infinity)
            case .invalid:
                VStack(spacing: 10) {
                    CrewIcon(size: 64, symbol: "link")
                    Text("이 초대 링크는 더 이상 쓸 수 없어요").font(.title2.bold()).multilineTextAlignment(.center)
                    Text("링크가 새로 만들어졌거나 크루가 사라졌어요. 크루장에게 새 링크를 받아 보세요.")
                        .foregroundStyle(Color.secondaryText).multilineTextAlignment(.center)
                }
                .padding(.top, 24)
                Spacer()
                Button("확인") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            case .failed:
                Text(failMessage).foregroundStyle(Color.secondaryText).multilineTextAlignment(.center).frame(maxHeight: .infinity)
                Button("다시 시도") { Task { await load() } }.buttonStyle(PrimaryButtonStyle())
            case .ready(let p):
                ScrollView {
                    VStack(spacing: 16) {
                        VStack(spacing: 6) {
                            CrewIcon(size: 64)
                            Text("크루 초대").font(.subheadline).foregroundStyle(Color.secondaryText).padding(.top, 6)
                            Text(p.name).font(.title.bold()).multilineTextAlignment(.center)
                            Text((p.full ? "\(p.count)/\(Crews.maxMembers)명" : "\(p.count)명") + (p.owner.isEmpty ? "" : " · 크루장 \(p.owner)"))
                                .foregroundStyle(Color.secondaryText)
                        }
                        if p.full {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("크루가 가득 찼어요").fontWeight(.semibold)
                                    Text("크루는 최대 50명까지예요. 자리가 나면 다시 참여할 수 있어요.").font(.subheadline).foregroundStyle(Color.secondaryText)
                                }
                            } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(light: 0xA87400, dark: 0xF2C14E)) }
                            .frame(maxWidth: .infinity, alignment: .leading).card(padding: 16)
                        } else if kicked {
                            Label("이 크루에 다시 참여할 수 없어요", systemImage: "exclamationmark.triangle")
                                .frame(maxWidth: .infinity, alignment: .leading).card(padding: 16)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("가입 전 이번 시즌 기록도 크루원에게 보여요", systemImage: "eye").fontWeight(.semibold)
                                FlowChips(items: ["방문일", "하강 횟수", "거리", "선택한 리조트별 방문일"])
                                Text("경로와 위치는 보이지 않아요.").font(.subheadline).foregroundStyle(Color.secondaryText)
                            }
                            .card(padding: 16)
                        }
                    }
                    .foregroundStyle(Color.primaryText)
                    .padding(.top, 20)
                }
                VStack(spacing: 8) {
                    Button(p.member ? "크루 열기" : "참여") { Task { await join(p) } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled((p.full && !p.member) || kicked || busy)
                        .opacity((p.full && !p.member) || kicked ? 0.4 : 1)
                        .overlay { if busy { ProgressView() } }
                    Button(p.full ? "닫기" : "취소") { dismiss() }.font(.headline).foregroundStyle(Color.primaryText).frame(minHeight: 52)
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .background(Color.bg.ignoresSafeArea())
        .presentationDetents(invalid ? [.medium] : [.large])
        .presentationDragIndicator(.visible)
        .task { await load() }
        .alert("참여하지 못했어요", isPresented: $failed) { Button("확인", role: .cancel) {} } message: { Text(failMessage) }
    }

    private var invalid: Bool { if case .invalid = state { true } else { false } }

    private func load() async {
        state = .loading
        do {
            let r = try await CrewAPI.call("previewInvite", ["token": token])
            state = .ready(Preview(name: r["name"] as? String ?? "", count: r["member_count"] as? Int ?? 0,
                                   owner: r["owner_name"] as? String ?? "", full: r["full"] as? Bool ?? false,
                                   member: r["already_member"] as? Bool ?? false))
        } catch {
            state = CrewAPI.code(error).0 == .notFound ? .invalid : .failed
        }
    }

    private func join(_ p: Preview) async {
        guard signedIn else { needSignUp(); return }
        busy = true
        defer { busy = false }
        do {
            let r = try await CrewAPI.call("joinCrew", ["token": token])
            if let id = r["crewId"] as? String { opened(id) }
        } catch {
            switch CrewAPI.code(error) {
            case (.notFound?, _): state = .invalid
            case (.resourceExhausted?, _): var q = p; q.full = true; state = .ready(q)
            case (.permissionDenied?, "kicked"): kicked = true
            default: failed = true
            }
        }
    }
}

// MARK: S14 크루 상세

struct CrewDetailView: View {
    var crews: Crews
    var summary: SummarySync
    var crewId: String
    @Environment(\.dismiss) private var dismiss
    @State private var metric = Crews.Metric.visitDays
    @State private var seen = false

    var body: some View {
        Group {
            if let crew = crews.crew(crewId) {
                content(crew)
            } else if crews.failedCrews.contains(crewId) {
                ContentUnavailableView {
                    Label("크루를 불러오지 못했어요", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("다시 시도") { crews.retry() }.buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.bg.ignoresSafeArea())
        // 나가거나 내보내지면 목록에서 빠진다 → 상세도 닫는다
        .onChange(of: crews.crew(crewId) == nil, initial: true) { _, gone in
            if gone && seen { dismiss() }
            if !gone { seen = true }
        }
    }

    private func content(_ crew: Crews.Crew) -> some View {
        let list = crews.ranking(crewId, by: metric)
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if summary.failed {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(light: 0xA87400, dark: 0xF2C14E))
                            .accessibilityHidden(true)
                        Text("최신 기록을 올리지 못했어요." + (synced.map { " 마지막 갱신 \($0)" } ?? "")).font(.subheadline)
                        Spacer(minLength: 0)
                        Button("다시 시도") { summary.sync(force: true) }.font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentText).frame(minHeight: 44)
                    }
                    .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
                    .background(Color.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
                    .padding(.bottom, 8)
                }
                Picker("순위 기준", selection: $metric) {
                    ForEach(Crews.Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(([Stats.season(of: .now).map { "\($0) 시즌" }, "\(crew.memberCount)명",
                       summary.failed ? nil : synced.map { "마지막 갱신 \($0)" }] as [String?]).compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Color.secondaryText).padding(.horizontal, 4).padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                        row(rank: i + 1, m)
                        if i < list.count - 1 { Divider().padding(.leading, 16) }
                    }
                }
                .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(metric.rawValue) 순위")
                if crew.memberCount <= 1 { alone(crew) }
            }
            .foregroundStyle(Color.primaryText)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
        }
        .navigationTitle(crew.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: crew.inviteURL, message: Text("SlopeMate 크루 '\(crew.name)'에 초대해요")) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("초대 링크 공유")
                NavigationLink { CrewSettingsView(crews: crews, crewId: crewId) } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("크루 설정")
            }
        }
    }

    private func row(rank: Int, _ m: Crews.Member) -> some View {
        let me = m.id == crews.uid
        return HStack(spacing: 12) {
            Text("\(rank)").font(.headline).monospacedDigit().frame(minWidth: 24)
            VStack(alignment: .leading, spacing: 1) {
                (Text(m.name).fontWeight(.semibold) + Text(me ? " (나)" : "").font(.subheadline).foregroundStyle(Color.secondaryText))
                Text(resorts(m)).font(.subheadline).foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 8)
            value(m).foregroundStyle(me ? Color.accentText : Color.primaryText)
        }
        .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 60)
        .background(me ? Color(light: 0xEEF6F8, dark: 0x183A44) : .clear)
        .accessibilityElement(children: .combine)
    }

    /// 내 합계를 서버가 마지막으로 받은 시각 "10:42"(오늘이 아니면 "11월 9일")
    private var synced: String? {
        summary.lastSynced.map { HomeData.seoul.isDateInToday($0) ? $0.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) : HomeData.monthDay($0) }
    }

    /// "하이원 10 · 웰리힐리파크 2"
    private func resorts(_ m: Crews.Member) -> String {
        let s = m.resortDays.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\(Resort.name($0.key)) \($0.value)" }
        return s.isEmpty ? "아직 방문 없음" : s.joined(separator: " · ")
    }

    private func value(_ m: Crews.Member) -> Text {
        let (n, unit): (String, String) = switch metric {
        case .visitDays: ("\(m.visitDays)", "일")
        case .runs: ("\(m.runs)", "회")
        case .distance: (m.distanceKm.formatted(.number.precision(.fractionLength(1))), "km")
        }
        return Text(n).font(.title3.bold()).monospacedDigit() + Text(unit).font(.subheadline.weight(.semibold))
    }

    private func alone(_ crew: Crews.Crew) -> some View {
        VStack(spacing: 12) {
            CrewIcon(size: 56, symbol: "link")
            Text("초대 링크를 보내 크루원을 모아 보세요").font(.title3.bold()).multilineTextAlignment(.center)
            Text("링크를 받은 사람이 열면 크루에 들어와요. 최대 50명까지 함께할 수 있어요.")
                .font(.subheadline).foregroundStyle(Color.secondaryText).multilineTextAlignment(.center)
            ShareLink(item: crew.inviteURL, message: Text("SlopeMate 크루 '\(crew.name)'에 초대해요")) {
                Label("초대 링크 공유", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.top, 8)
        .card(padding: 16)
        .padding(.top, 8)
    }
}

// MARK: S15 크루 설정

struct CrewSettingsView: View {
    var crews: Crews
    var crewId: String
    @State private var renaming = false
    @State private var rotating = false
    @State private var leaving = false
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        if let crew = crews.crew(crewId) {
            let owner = crew.ownerUid == crews.uid
            let ownerName = crews.members[crewId]?.first { $0.id == crew.ownerUid }?.name ?? ""
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        CrewIcon(size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(crew.name).font(.title3.bold())
                            Text("\(crew.memberCount)/\(Crews.maxMembers)명 · 크루장 \(ownerName)\(owner ? "(나)" : "")")
                                .font(.subheadline).foregroundStyle(Color.secondaryText)
                        }
                    }
                    .card(padding: 16)

                    if owner {
                        section("크루장")
                        group {
                            item("크루 이름 바꾸기", "pencil") { renaming = true }
                            Divider()
                            item("초대 링크 새로 만들기", "arrow.clockwise") { rotating = true }
                            Divider()
                            NavigationLink { KickMembersView(crews: crews, crewId: crewId) } label: {
                                itemLabel("크루원 내보내기", "person.badge.minus", trailing: "\(max(crew.memberCount - 1, 0))명")
                            }
                            .buttonStyle(.plain)
                            Divider()
                            NavigationLink { BansView(crewId: crewId) } label: { itemLabel("차단한 사람", "hand.raised") }
                                .buttonStyle(.plain)
                        }
                        note("초대 링크를 새로 만들면 이전 링크는 더 이상 쓸 수 없어요. 초대 링크를 받은 사람은 가입 전에도 크루장 표시 이름을 볼 수 있어요.")
                    }

                    section("크루")
                    group {
                        // 크루 이름·표시 이름 신고는 신고 단계(R16)에서 붙인다
                        Button { leaving = true } label: {
                            itemLabel("크루 나가기", "rectangle.portrait.and.arrow.right", tint: Color(light: 0x8A1C1C, dark: 0xFF8A80))
                        }
                        .buttonStyle(.plain)
                    }
                    note(owner ? "나가면 이 크루에서 내 기록이 사라져요. 크루장이 나가면 다음 가입자가 크루장이 돼요."
                               : "나가면 이 크루에서 내 기록이 사라져요.")
                }
                .foregroundStyle(Color.primaryText)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
            }
            .background(Color.bg.ignoresSafeArea())
            .navigationTitle("크루 설정").navigationBarTitleDisplayMode(.inline)
            .disabled(busy)
            .sheet(isPresented: $renaming) { RenameCrewSheet(crew: crew) }
            .alert("초대 링크를 새로 만들까요?", isPresented: $rotating) {
                Button("취소", role: .cancel) {}
                Button("새로 만들기") { run("rotateInvite", ["crewId": crewId]) }
            } message: { Text("이전 링크는 더 이상 쓸 수 없어요.") }
            .alert("\(crew.name)에서 나갈까요?", isPresented: $leaving) {
                Button("취소", role: .cancel) {}
                Button("나가기", role: .destructive) { run("leaveCrew", ["crewId": crewId]) }
            } message: { Text("이 크루에서 내 기록이 사라지고, 크루 기록도 볼 수 없어요.") }
            .alert("처리하지 못했어요", isPresented: $failed) { Button("확인", role: .cancel) {} } message: { Text(failMessage) }
        }
    }

    private func run(_ fn: String, _ data: [String: Any]) {
        busy = true
        Task {
            do { _ = try await CrewAPI.call(fn, data) } catch { failed = true }
            busy = false
        }
    }

    private func section(_ t: String) -> some View {
        Text(t).font(.subheadline.weight(.semibold)).padding(.horizontal, 4).padding(.top, 14)
    }
    private func note(_ t: String) -> some View {
        Text(t).font(.subheadline).foregroundStyle(Color.secondaryText).padding(.horizontal, 4)
    }
    private func group(@ViewBuilder _ c: () -> some View) -> some View {
        VStack(spacing: 0, content: c).padding(.horizontal, 16)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
    }
    private func item(_ t: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { itemLabel(t, icon, trailing: nil) }.buttonStyle(.plain)
    }
    private func itemLabel(_ t: String, _ icon: String, trailing: String? = nil, tint: Color = .accentText) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 24).accessibilityHidden(true)
            Text(t).foregroundStyle(tint == .accentText ? Color.primaryText : tint)
            Spacer(minLength: 0)
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(Color.secondaryText) }
            if tint == .accentText {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
            }
        }
        .frame(minHeight: 52).contentShape(Rectangle())
    }
}

/// 크루 이름 바꾸기 (크루장)
private struct RenameCrewSheet: View {
    var crew: Crews.Crew
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextField("크루 이름", text: $name)
                    .onChange(of: name) { if name.unicodeScalars.count > 20 { name = String(name.prefix(20)) } }
                    .padding(.horizontal, 16).frame(minHeight: 52)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.cardBorder))
                Text("\(name.trimmingCharacters(in: .whitespaces).unicodeScalars.count)/20")
                    .font(.subheadline).monospacedDigit().foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Spacer()
            }
            .padding(16)
            .background(Color.bg.ignoresSafeArea())
            .navigationTitle("크루 이름 바꾸기").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        guard let n = Account.cleanName(name) else { return }
                        busy = true
                        Task {
                            do { _ = try await CrewAPI.call("renameCrew", ["crewId": crew.id, "name": n]); dismiss() } catch { failed = true }
                            busy = false
                        }
                    }
                    .disabled(Account.cleanName(name) == nil || busy)
                }
            }
            .alert("이름을 바꾸지 못했어요", isPresented: $failed) { Button("확인", role: .cancel) {} } message: { Text(failMessage) }
            .onAppear { name = crew.name }
        }
        .presentationDetents([.medium])
    }
}

/// 크루원 내보내기 (크루장, R16)
private struct KickMembersView: View {
    var crews: Crews
    var crewId: String
    @State private var target: Crews.Member?
    @State private var failed = false

    var body: some View {
        let others = (crews.members[crewId] ?? []).filter { $0.id != crews.uid }.sorted { $0.joinedAt < $1.joinedAt }
        List(others) { m in
            HStack {
                Text(m.name)
                Spacer()
                Button("내보내기", role: .destructive) { target = m }
            }
        }
        .overlay { if others.isEmpty { ContentUnavailableView("내보낼 크루원이 없어요", systemImage: "person.2") } }
        .navigationTitle("크루원 내보내기").navigationBarTitleDisplayMode(.inline)
        .alert("\(target?.name ?? "")님을 내보낼까요?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            Button("취소", role: .cancel) {}
            Button("내보내기", role: .destructive) {
                guard let m = target else { return }
                Task {
                    do { _ = try await CrewAPI.call("kickMember", ["crewId": crewId, "uid": m.id]) } catch { failed = true }
                }
            }
        } message: { Text("이 크루에서 기록이 사라져요. 새 초대 링크를 받아도 이 크루에 다시 참여할 수 없어요. 크루 설정의 차단한 사람에서 풀 수 있어요.") }
        .alert("내보내지 못했어요", isPresented: $failed) { Button("확인", role: .cancel) {} } message: { Text(failMessage) }
    }
}

/// 차단한 사람 (크루장, R16). 내보낸 사람은 여기서 풀어야 다시 참여할 수 있다.
private struct BansView: View {
    var crewId: String
    private struct Ban: Identifiable { let id: String; let name: String }
    @State private var bans: [Ban]?
    @State private var target: Ban?
    @State private var failed = false

    var body: some View {
        Group {
            if let bans {
                List(bans) { b in
                    HStack {
                        Text(b.name.isEmpty ? "이름 없음" : b.name)
                        Spacer()
                        Button("차단 해제") { target = b }
                    }
                }
                .overlay { if bans.isEmpty { ContentUnavailableView("차단한 사람이 없어요", systemImage: "hand.raised") } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("차단한 사람").navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("\(target?.name ?? "")님의 차단을 풀까요?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            Button("취소", role: .cancel) {}
            Button("차단 해제") {
                guard let b = target else { return }
                Task {
                    do { _ = try await CrewAPI.call("unbanMember", ["crewId": crewId, "uid": b.id]); await load() } catch { failed = true }
                }
            }
        } message: { Text("초대 링크로 이 크루에 다시 참여할 수 있게 돼요.") }
        .alert("처리하지 못했어요", isPresented: $failed) { Button("확인", role: .cancel) {} } message: { Text(failMessage) }
    }

    private func load() async {
        do {
            let snap = try await Firestore.firestore().collection("crews").document(crewId).collection("bans").getDocuments()
            bans = snap.documents.map { Ban(id: $0.documentID, name: $0.get("display_name") as? String ?? "") }
        } catch {
            failed = true
            bans = bans ?? []
        }
    }
}
