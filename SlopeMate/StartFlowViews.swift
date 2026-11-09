import SwiftUI
import UIKit

// 기록 시작 흐름 (B3 확정, 04-flows 1장): S1 홈 리조트 선택, S3 리조트 고르기, 첫 기록 익명 동의, S4 위치 권한, S7 끊김 복구·영업일 끝 안내.

extension Resort {
    /// 목록 묶음(지역)과 아래 줄(도시). 내장 리조트 12곳 (S1·S3 시안).
    static let places: [String: (region: String, city: String)] = [
        "high1": ("강원", "정선"), "yongpyong": ("강원", "평창"), "vivaldi": ("강원", "홍천"), "phoenix": ("강원", "평창"),
        "wellihilli": ("강원", "횡성"), "alpensia": ("강원", "평창"), "elysian": ("강원", "춘천"), "o2": ("강원", "태백"),
        "konjiam": ("경기", "광주"), "jisan": ("경기", "이천"), "muju": ("그 외", "전북 무주"), "edenvalley": ("그 외", "경남 양산"),
    ]

    /// 지역별 묶음, 묶음 안은 가나다순
    static var byRegion: [(region: String, resorts: [Resort])] {
        ["강원", "경기", "그 외"].map { region in
            (region, all.filter { (places[$0.id]?.region ?? "그 외") == region }.sorted { $0.name < $1.name })
        }
    }

    var city: String { Self.places[id]?.city ?? "" }

    /// "강원 평창". 그 외 지역은 도시에 도 이름이 들어 있다.
    var place: String {
        guard let p = Self.places[id] else { return "" }
        return p.region == "그 외" ? p.city : "\(p.region) \(p.city)"
    }
}

extension Color {
    /// 고른 행 (밝게 옅은 청록, 어둡게 #1E4A56)
    static let selectedRow = Color(light: 0xE1F3F5, dark: 0x1E4A56)
    static let rowDivider = Color(light: 0xE3ECEF, dark: 0x23404B)
}

// MARK: 목록 부품

/// 리조트 행: 이름과 아래 줄. 고르면 옅은 청록 면과 굵은 이름.
private struct ResortRow<Mark: View>: View {
    var name: String
    var detail: String
    var selected: Bool
    @ViewBuilder var mark: Mark
    var tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.body.weight(selected ? .bold : .regular)).foregroundStyle(Color.primaryText)
                    Text(detail).font(.subheadline).foregroundStyle(Color.secondaryText)
                }
                Spacer(minLength: 0)
                mark
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(selected ? Color.selectedRow : .clear)
            .overlay(alignment: .top) { Color.rowDivider.frame(height: 1) } // 첫 행은 카드 테두리가 덮는다
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 흰 카드. 행마다 위 구분선을 긋고, 첫 행의 선은 카드 테두리가 덮는다.
private struct RowCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
    }
}

/// 지역별 전체 리조트 목록 (검색 없음)
private struct RegionList<Mark: View>: View {
    var isSelected: (String) -> Bool
    var tap: (String) -> Void
    @ViewBuilder var mark: (Bool) -> Mark

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Resort.byRegion, id: \.region) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.region).font(.subheadline.weight(.semibold)).foregroundStyle(Color.secondaryText)
                        .padding(.horizontal, 16).accessibilityAddTraits(.isHeader)
                    RowCard {
                        ForEach(group.resorts) { r in
                            let on = isSelected(r.id)
                            ResortRow(name: r.name, detail: r.city, selected: on, mark: { mark(on) }) { tap(r.id) }
                        }
                    }
                }
            }
        }
    }
}

/// 아래 고정 버튼. 고르기 전엔 비활성 "리조트를 골라 주세요".
private struct BottomButton: View {
    var title: String?
    var action: () -> Void
    var body: some View {
        if let title {
            Button(title, action: action).buttonStyle(PrimaryButtonStyle())
        } else {
            Text("리조트를 골라 주세요")
                .font(.title3.weight(.bold)).foregroundStyle(Color.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(Color.primaryText.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
                .accessibilityAddTraits(.isButton).accessibilityRemoveTraits(.isStaticText)
                .accessibilityHint("비활성")
        }
    }
}

private struct CheckCircle: View {
    var on: Bool
    var body: some View {
        if on {
            Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(Color.onAccent)
                .frame(width: 28, height: 28).background(Color.accentFill, in: Circle())
        } else {
            Circle().strokeBorder(Color.secondaryText, lineWidth: 1.5).frame(width: 26, height: 26)
        }
    }
}

private struct CheckMark: View {
    var on: Bool
    var body: some View {
        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentText)
            .frame(width: 24).opacity(on ? 1 : 0)
    }
}

/// 시트 머리: 왼쪽 원 버튼(닫기 X 또는 뒤로 ←), 가운데 제목, 아래 설명
private struct SheetHeader: View {
    var back: Bool
    var title: String
    var subtitle: String
    var action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button(action: action) {
                    Image(systemName: back ? "chevron.left" : "xmark").font(.body.weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge) // 원 안에 머물게
                        .frame(width: 44, height: 44).glassCircle()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(back ? "뒤로" : "닫기")
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity).accessibilityAddTraits(.isHeader)
                Color.clear.frame(width: 44, height: 1)
            }
            Text(subtitle).font(.subheadline).foregroundStyle(Color.secondaryText).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.primaryText)
    }
}

// MARK: S1 홈 리조트 선택 (v3)

/// 첫 실행에 한 번, 탭 위 전체 화면. 고른 순서가 S3 목록 순서가 된다. 저장에 성공해야 완료로 남긴다.
struct HomeSetupView: View {
    let db: AppDatabase
    /// 설정에서 열 때만: 저장하지 않고 닫는다
    var cancel: (() -> Void)? = nil
    var done: () -> Void
    @State private var picked: [String] = []
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cancel {
                Button("취소", action: cancel).font(.body.weight(.semibold)).foregroundStyle(Color.accentText)
                    .frame(minHeight: 44).padding(.horizontal, 20).padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("자주 가는 리조트").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("선택한 리조트를 기록 시작 화면에 먼저 보여드려요. 여러 곳을 선택할 수 있어요.")
                    .foregroundStyle(Color.secondaryText)
            }
            .padding(.horizontal, 20).padding(.top, 24)

            if !picked.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(picked, id: \.self) { id in
                            Button { toggle(id) } label: {
                                HStack(spacing: 4) {
                                    Text(Resort.name(id)).font(.subheadline.weight(.semibold))
                                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Color.secondaryText)
                                        .frame(width: 28, height: 28)
                                }
                                .padding(.leading, 16).padding(.trailing, 8).frame(minHeight: 44)
                                .background(Color.selectedRow, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.accentFill))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(Resort.name(id)) 선택 해제")
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 14)
            }

            ScrollView {
                RegionList(isSelected: picked.contains, tap: toggle) { CheckCircle(on: $0) }
                    .padding(.horizontal, 16).padding(.vertical, 16)
            }
        }
        .foregroundStyle(Color.primaryText)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                BottomButton(title: picked.isEmpty ? nil : "\(picked.count)곳 선택 완료") { save(picked) }
                Button { save([]) } label: {
                    Text("자주 가는 곳이 없어요").font(.body.weight(.semibold)).foregroundStyle(Color.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.cardBorder))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            .background(Color.bg)
            .overlay(alignment: .top) { Color.rowDivider.frame(height: 1) }
        }
        .background(Color.bg)
        .task { picked = (try? db.homeResorts()) ?? [] }
        .alert("저장하지 못했어요", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("확인") {}
        } message: { Text(saveError ?? "") }
    }

    private func toggle(_ id: String) {
        if let i = picked.firstIndex(of: id) { picked.remove(at: i) } else { picked.append(id) }
    }

    private func save(_ ids: [String]) {
        do {
            try Settings.saveHomeSetup(ids, db: db)
            done()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: S3 기록 시작 시트 (작은 시트 v2, 전체 목록 v3)

/// 홈 리조트 중 하나(기본: 마지막으로 기록한 리조트)를 고르거나, 전체 목록에서 이번 기록만의 리조트를 고른다.
/// 홈 리조트가 없으면 전체 목록이 바로 열린다(X로 닫음).
struct ResortPickSheet: View {
    let homes: [String]
    var choose: (String) -> Void
    @State private var selected: String?
    @State private var other: String?
    @State private var all: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(homes: [String], choose: @escaping (String) -> Void) {
        self.homes = homes
        self.choose = choose
        _selected = State(initialValue: AppDatabase.defaultResort(homes: homes, last: Recorder.lastResortId))
        _all = State(initialValue: homes.isEmpty)
    }

    var body: some View {
        VStack(spacing: 12) {
            if all { fullList } else { small }
        }
        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 8)
        // 아주 큰 글씨에서는 작은 시트에 다 들어가지 않으니 크게 연다
        .presentationDetents(all || typeSize.isAccessibilitySize ? [.large] : [.height(smallHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.bg) // 유리 시트 뒤로 기록 시작 카드가 비쳐 글자가 묻힌다
    }

    private var smallHeight: CGFloat { 270 + 64 * CGFloat(min(homes.count, 4)) }

    private var small: some View {
        VStack(spacing: 12) {
            // 머리말·리조트·다른 리조트 찾기를 한 스크롤에 둔다(큰 글씨에서 서로 겹치지 않게). 시작 버튼은 아래에 남는다.
            ScrollView {
                VStack(spacing: 12) {
                    SheetHeader(back: false, title: "어디서 타나요?", subtitle: "이번 기록을 남길 리조트를 선택해 주세요.") { dismiss() }
                    RowCard {
                        ForEach(homes, id: \.self) { id in
                            let r = Resort.all.first { $0.id == id }
                            ResortRow(name: Resort.name(id), detail: id == Recorder.lastResortId ? "마지막으로 기록한 리조트" : r?.place ?? "",
                                      selected: selected == id, mark: { CheckMark(on: selected == id) }) { selected = id }
                        }
                    }
                    Color.rowDivider.frame(height: 1).padding(.top, 8)
                    Button { all = true } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("다른 리조트 찾기").font(.body.weight(.semibold)).foregroundStyle(Color.accentText)
                                Text("이번 기록에만 적용돼요").font(.subheadline).foregroundStyle(Color.secondaryText)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.accentText)
                        }
                        .padding(.leading, 16).padding(.trailing, 8)
                        .frame(minHeight: 56).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            BottomButton(title: selected.map { "\(Resort.name($0))에서 기록 시작" }) { selected.map(choose) }
        }
    }

    private var fullList: some View {
        VStack(spacing: 12) {
            // 머리말도 목록과 함께 스크롤된다(큰 글씨에서 머리말이 목록 자리를 차지하지 않게)
            ScrollView {
                VStack(spacing: 12) {
                    SheetHeader(back: !homes.isEmpty, title: "어디서 타나요?",
                                subtitle: homes.isEmpty ? "자주 가는 리조트가 없어 전체 목록을 보여드려요" : "이번 기록에만 적용돼요") {
                        if homes.isEmpty { dismiss() } else { all = false; other = nil }
                    }
                    RegionList(isSelected: { other == $0 }, tap: { other = $0 }) { CheckMark(on: $0) }
                        .padding(.vertical, 4)
                }
            }
            BottomButton(title: other.map { "\(Resort.name($0))에서 기록 시작" }) { other.map(choose) }
                .padding(.top, 12)
                .overlay(alignment: .top) { Color.rowDivider.frame(height: 1).padding(.horizontal, -16) }
        }
    }
}

// MARK: 첫 기록 익명 전송 동의 (v2, R12)

/// 첫 기록을 시작할 때 한 번. 닫기 없음. 어느 답이든 기록은 시작한다.
struct ConsentSheet: View {
    var answer: (Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("설질·대기 시간을 익명으로 보낼까요?").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text("직접 남긴 설질 평가와 자동으로 측정한 리프트 대기 시간을 익명으로 모아 리조트별 현황을 보여줘요.")
                        .font(.subheadline).foregroundStyle(Color.secondaryText)
                }
                .padding(.horizontal, 4)
                list("보내는 것", icon: "checkmark", tint: .accentText,
                     [("리조트", nil), ("슬로프·리프트", nil), ("15분 단위 시간대", "예: 10:30~10:45"), ("설질·대기 시간", nil)])
                list("보내지 않는 것", icon: "xmark", tint: .secondaryText,
                     [("계정", nil), ("GPS 좌표와 이동 경로", nil), ("정확한 시각", nil)])
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Color.accentText)
                    Text("보내지 않아도 기록은 똑같이 돼요. 설정에서 언제든 바꿀 수 있어요.")
                }
                .font(.subheadline)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 16).padding(.top, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(Color.primaryText)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                Button("보내기") { answer(true) }.buttonStyle(PrimaryButtonStyle())
                Button { answer(false) } label: {
                    Text("보내지 않기").font(.body.weight(.semibold)).foregroundStyle(Color.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.primaryText.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.bg)
        .interactiveDismissDisabled()
    }

    private func list(_ title: String, icon: String, tint: Color, _ items: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).padding(.leading, 4).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    if i > 0 { Color.rowDivider.frame(height: 1) }
                    HStack(spacing: 10) {
                        Image(systemName: icon).font(.footnote.weight(.bold)).foregroundStyle(tint).frame(width: 20)
                            .accessibilityHidden(true)
                        Text(item.0)
                        Spacer(minLength: 0)
                        if let note = item.1 { Text(note).monospacedDigit().foregroundStyle(Color.secondaryText) }
                    }
                    .font(.subheadline)
                    .frame(minHeight: 36)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
        }
    }
}

// MARK: S4 위치 권한 안내 (v3, 거부됨 v2)

/// S3에서 고른 리조트를 들고 권한을 기다린다. 허용되면 Recorder가 그 리조트로 시작해 S5로 바뀐다.
struct PermissionView: View {
    var recorder: Recorder
    var later: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let b = recorder.blocked { blocked(b) } else { intro }
                }
                .padding(.vertical, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center)
            VStack(spacing: 10) {
                if recorder.blocked == .servicesOff {
                    Button("설정 열기", action: openSettings).buttonStyle(PrimaryButtonStyle())
                } else if recorder.blocked != nil {
                    Button("설정에서 권한 켜기", action: openSettings).buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("권한 설정하기") { recorder.requestPermission() }.buttonStyle(PrimaryButtonStyle())
                }
                Button(action: later) {
                    Text("나중에").font(.body.weight(.semibold)).foregroundStyle(Color.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.cardBorder))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .foregroundStyle(Color.primaryText)
        .background(Color.bg)
    }

    private func openSettings() { openURL(URL(string: UIApplication.openSettingsURLString)!) }

    private func head(_ icon: String, _ title: String, _ body: String, dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.title).foregroundStyle(Color.accentText)
                .frame(width: 72, height: 72).background(Color.surface, in: Circle()).accessibilityHidden(true)
            Text(title).font(.title.bold()).padding(.top, 8).accessibilityAddTraits(.isHeader)
            Text(body).foregroundStyle(dim ? Color.secondaryText : Color.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var intro: some View {
        head("location.fill", "기록하려면 위치가 필요해요", "기록 중에만 위치를 써서 하강 횟수와 거리를 재요. GPS 기록은 우리 서버로 보내지 않습니다.", dim: false)
        RowCard {
            permission("location", "위치 · 정확한 위치", required: true, "위치로 하강 횟수와 이동 거리를 기록해요.")
            permission("figure.skiing.downhill", "동작 및 피트니스", required: false, "고도를 정확히 재려고 기압계를 씁니다. 허용하지 않아도 기록은 돼요.")
        }
        .padding(.horizontal, 16)
    }

    private func permission(_ icon: String, _ title: String, required: Bool, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).foregroundStyle(Color.accentText)
                .frame(width: 44, height: 44).background(Color.surface, in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.body.weight(.semibold))
                    Text(required ? "필수" : "선택").font(.footnote.bold())
                        .foregroundStyle(required ? Color.onAccent : Color.secondaryText)
                        .padding(.horizontal, 8).frame(minHeight: 24)
                        .background(required ? Color.accentFill : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(required ? .clear : Color.secondaryText))
                }
                Text(detail).font(.subheadline).foregroundStyle(Color.secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Color.rowDivider.frame(height: 1) }
    }

    @ViewBuilder private func blocked(_ b: Recorder.Blocked) -> some View {
        switch b {
        case .denied:
            head("location.slash", "기록을 시작하려면 위치 권한을 켜주세요",
                 "위치 권한이 꺼져 있어 기록을 시작할 수 없어요. 설정에서 위치 접근을 허용해 주세요.", dim: true)
            steps(["설정에서 **위치**를 누르세요", "**앱을 사용하는 동안**을 선택하세요", "**정확한 위치**를 켜세요"])
        case .reducedAccuracy:
            head("scope", "정확한 위치를 켜야 슬로프를 셀 수 있어요",
                 "대략적인 위치로는 하강을 셀 수 없어요. 설정에서 정확한 위치를 켜 주세요.", dim: true)
            steps(["설정에서 **위치**를 누르세요", "**정확한 위치**를 켜세요"])
        case .servicesOff:
            head("location.slash", "위치 서비스가 꺼져 있어요",
                 "iPhone의 위치 서비스가 꺼져 있어 기록을 시작할 수 없어요.", dim: true)
            steps(["**설정** 앱에서 **개인정보 보호 및 보안**을 누르세요", "**위치 서비스**를 누르세요", "**위치 서비스**를 켜세요"])
        }
    }

    private func steps(_ lines: [LocalizedStringKey]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("설정에서 켜는 법").font(.body.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                HStack(spacing: 14) {
                    Text("\(i + 1)").font(.body.bold()).foregroundStyle(Color.accentText)
                        .frame(width: 32, height: 32).background(Color.surface, in: Circle()).accessibilityHidden(true)
                    Text(line)
                }
            }
        }
        .card(padding: 20)
        .padding(.horizontal, 16)
    }
}

// MARK: S7 끊김 복구 (같은 영업일 v1, 영업일 끝 v2)

/// 같은 영업일에 오래 끊긴 기록(이어서·끝내기) 또는 06:00이 지나 이미 끝낸 기록 안내(하루 기록 보기)
enum ResumePrompt: Identifiable {
    case resume(Recording)
    case dayEnd(Recording)

    var id: String {
        switch self {
        case .resume(let r): "resume-\(r.id)"
        case .dayEnd(let r): "dayEnd-\(r.id)"
        }
    }
}

struct ResumeSheet: View {
    let db: AppDatabase
    let prompt: ResumePrompt
    var resume: () -> Void
    var end: () -> Void
    var openDay: () -> Void
    @State private var brief: (last: Date, runs: Int)?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 12) {
            // 큰 글씨에서는 설명이 길어져 스크롤된다. 버튼은 아래에 남는다.
            ScrollView {
            VStack(spacing: 8) {
                Image(systemName: isDayEnd ? "moon.zzz" : "pause.circle").font(.title).foregroundStyle(Color.accentText)
                    .frame(width: 64, height: 64).background(Color.surface, in: Circle()).accessibilityHidden(true)
                Text(isDayEnd ? "지난 기록을 마쳤어요" : "기록이 중간에 끊겼어요").font(.title2.bold()).padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
                if let brief {
                    Text("마지막 저장 \(ResumeText.lastSaved(brief.last)) · \(Resort.name(rec.resortId)) · \(brief.runs)회").monospacedDigit()
                }
                Text(isDayEnd ? "오전 6시가 지나 지난 기록을 마쳤어요. \(Resort.name(rec.resortId))에서의 하강 \(brief?.runs ?? 0)회는 저장됐어요."
                     : "이어서 기록하면 같은 하루 기록에 붙어요.")
                    .font(.subheadline).foregroundStyle(Color.secondaryText)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 32)
            }
            .scrollBounceBehavior(.basedOnSize)
            if isDayEnd {
                Button("하루 기록 보기", action: openDay).buttonStyle(PrimaryButtonStyle())
            } else {
                Button("이어서 기록", action: resume).buttonStyle(PrimaryButtonStyle())
                Button(action: end) {
                    Text("여기서 끝내기").font(.title3.weight(.bold)).foregroundStyle(Color.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(Color.surface, in: RoundedRectangle(cornerRadius: 24))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(Color.primaryText)
        .padding(.horizontal, 16).padding(.bottom, 8)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.bg)
        .interactiveDismissDisabled(!isDayEnd)
        .task { brief = db.brief(rec) }
    }

    private var isDayEnd: Bool { if case .dayEnd = prompt { true } else { false } }
    private var rec: Recording {
        switch prompt { case .resume(let r), .dayEnd(let r): r }
    }
}

nonisolated enum ResumeText {
    /// "13:02", "어제 16:41", "12월 3일 16:41" (한국 시간, 달력 날짜 기준)
    static func lastSaved(_ t: Date, now: Date = .now) -> String {
        let cal = HomeData.seoul
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = cal.locale
        f.dateFormat = "HH:mm"
        let time = f.string(from: t)
        if cal.isDate(t, inSameDayAs: now) { return time }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(t, inSameDayAs: y) { return "어제 \(time)" }
        f.dateFormat = "M월 d일 HH:mm"
        return f.string(from: t)
    }
}

extension AppDatabase {
    /// S7·영업일 끝 안내 한 줄: 마지막 저장 시각과 하강 수
    @MainActor func brief(_ rec: Recording) -> (last: Date, runs: Int)? {
        guard let points = try? points(rec) else { return nil }
        let map = SlopeMap.cached(resortId: rec.resortId)
        let runs = rec.endedAt == nil ? RunDetector.detect(points, vehicle: (try? vehicle(rec)) ?? [], map: map).runs.count
            : ((try? cache(rec, map: map).summary.runs.count) ?? 0)
        return (points.last?.t ?? rec.startedAt, runs)
    }

    /// 끝난 기록이 속한 하루 기록(S6)
    func day(of rec: Recording) -> Stats.Day? {
        let date = BusinessDay.start(of: rec.startedAt)
        return (try? HomeData.days(self, since: date))?.first { $0.date == date && $0.resortId == rec.resortId }
    }
}
