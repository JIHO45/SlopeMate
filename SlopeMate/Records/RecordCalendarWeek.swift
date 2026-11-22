import SwiftUI

/// S8 주 보기 (v16): 요일 줄, 고른 날 기록마다 넘기는 카드(1장 3D 정지 그림, 2장 대표 사진)
extension RecordCalendarView {
    func weekView(_ every: [Stats.Day]) -> some View {
        let all = Stats.days(every, inSeason: season) // 시즌 밖(10월·5월) 날은 세지 않는다
        let found = RecordCalendar.weeks(season: season)
        let weeks = found.isEmpty ? [RecordCalendar.weekStart(HomeData.seasonStart(season))] : found
        let t = Stats.totals(RecordCalendar.days(all, in: RecordCalendar.weekInterval(week)))
        let i = weeks.firstIndex(of: week) ?? weeks.count - 1
        let recs = records(on: selected, all)
        let title = Self.dayTitle.string(from: selected)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    navHeader(RecordCalendar.weekRange(week), "\(t.visitDays)일 · \(t.runs)회", unit: "주",
                              prev: i > 0 ? { pick(week: weeks[i - 1]) } : nil,
                              next: i < weeks.count - 1 ? { pick(week: weeks[i + 1]) } : nil)
                    dayStrip(all)
                    Text(title)
                        .font(.title3.weight(.bold)).foregroundStyle(Color.primaryText)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.horizontal, 16)
                if recs.isEmpty {
                    Text("이날은 기록이 없어요")
                        .font(.body.weight(.semibold)).foregroundStyle(Color.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .overlay(RoundedRectangle(cornerRadius: 28)
                            .strokeBorder(Color.cardBorder, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                        .padding(.leading, 16).padding(.trailing, 16 + 28) // 넘기는 카드 한 장과 같은 크기
                } else {
                    ForEach(recs) { r in
                        DayPager(db: db, day: r, title: title, photo: large[r.id],
                                 pickPhoto: { pickPhoto(r) }, removePhoto: { removePhoto(r) }, delete: { deleting = r })
                    }
                }
            }
            .padding(.vertical, 16)
        }
    }

    private func dayStrip(_ all: [Stats.Day]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(RecordCalendar.weekDays(week).enumerated()), id: \.element) { i, d in
                let recs = records(on: d, all)
                let on = d == selected
                let future = d > today
                Button { selected = d } label: {
                    VStack(spacing: 6) {
                        Text(Self.weekdays[i]).font(.footnote).tracking(3).foregroundStyle(Color.secondaryText)
                        Text("\(RecordCalendar.cal.component(.day, from: d))")
                            .font(.body.weight(on ? .bold : .regular)).monospacedDigit()
                            .foregroundStyle(Color.primaryText)
                        HStack(spacing: 3) {
                            ForEach(recs) { r in
                                if r.isVisit {
                                    Circle().fill(Color.accentFill).frame(width: 6, height: 6)
                                } else {
                                    Circle().strokeBorder(Color.accentText, lineWidth: 1).frame(width: 6, height: 6)
                                }
                            }
                        }
                        .frame(height: 6)
                    }
                    .frame(width: 48, height: 72)
                    .background(on ? Color.card : .clear, in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        if d == today { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentText, lineWidth: 1.5) }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(future)
                .opacity(future ? 0.4 : 1)
                .accessibilityLabel(Self.dayTitle.string(from: d) + (recs.isEmpty ? ", 기록 없음"
                    : ", " + recs.map { "\(Resort.name($0.resortId)) \($0.runs.count)회" }.joined(separator: ", ")))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
        .background(Color.accentFill.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
    }
}

/// 하루 기록 하나의 넘기는 카드 두 장: 1장 3D 정지 그림, 2장 대표 사진(없으면 붙이기 칸)
private struct DayPager: View {
    let db: AppDatabase
    let day: Stats.Day
    let title: String              // "12월 20일 일요일"
    let photo: UIImage?
    let pickPhoto: () -> Void
    let removePhoto: () -> Void
    let delete: () -> Void
    @State private var page: Int? = 0
    @State private var still: UIImage?
    @State private var stillDone = false
    @State private var showPhoto = false   // ⋯에서 사진을 고르면 붙은 뒤 2장으로
    @Environment(\.colorScheme) private var systemScheme
    // 이미지로 공유(R31): 3D는 시즌 이용권, 없으면 2D 지도. 경로가 담기면 처음 한 번 알린다
    @Environment(SeasonTicket.self) private var ticket
    @AppStorage("shareNoticeShown") private var noticeShown = false
    @State private var pendingShare: ShareImage.Kind?
    @State private var sharing = false
    @State private var showTicket = false

    private static let teal = Color(red: 0x0F / 255, green: 0x3D / 255, blue: 0x45 / 255)
    private var resort: String { Resort.name(day.resortId) }

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    card(0) { stillPage }
                    card(1) { photoPage }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $page, anchor: .center)
            .scrollClipDisabled()
            HStack(spacing: 8) {
                ForEach(0..<2, id: \.self) { i in
                    Circle().fill(i == (page ?? 0) ? Color.accentText : Color.cardBorder).frame(width: 7, height: 7)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
        .task(id: "\(day.id)-\(day.runs.count)") {
            let img = await DayStill.image(day, db: db)
            guard !Task.isCancelled else { return } // 취소되면 nil이 오므로 실패 카드로 바꾸지 않는다
            still = img
            stillDone = true
        }
        .onChange(of: photo) { _, p in
            if showPhoto, p != nil { showPhoto = false; withAnimation { page = 1 } }
        }
        .alert("오늘 경로가 담겨요", isPresented: Binding { pendingShare != nil } set: { if !$0 { pendingShare = nil } }) {
            Button("취소", role: .cancel) {}
            Button("계속") { noticeShown = true; if let k = pendingShare { share(k) } }
        } message: {
            Text(ShareImage.routeNotice)
        }
        .sheet(isPresented: $showTicket) { SeasonTicketView() }
    }

    private var lock: SeasonRecap.Lock { DayMapView.lock(day: day.date, owned: ticket.seasons) }

    /// 보이는 장 기준: 사진 장이면 사진, 3D 장이면 3D(이용권 없으면 2D 지도)
    private func kind(_ i: Int) -> ShareImage.Kind { i == 1 && photo != nil ? .photo : lock == .open ? .threeD : .map }

    private func share(_ k: ShareImage.Kind) {
        if k.hasRoute, !noticeShown { pendingShare = k; return }
        sharing = true
        Task {
            await ShareImage.share(k, day: day, db: db)
            sharing = false
        }
    }

    /// 4:3 장: 그림 + 아래 유리 띠 + 오른쪽 위 ⋯
    private func card(_ i: Int, @ViewBuilder _ content: () -> some View) -> some View {
        // 3D 그림은 어둡게에서도 밝은 그림, 사진은 아래를 어둡게 하므로 띠·⋯도 그에 맞춘다
        let scheme: ColorScheme = i == 0 ? .light : photo != nil ? .dark : systemScheme
        return Color.clear
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay { content() }
            .overlay(alignment: .bottom) { caption.environment(\.colorScheme, scheme) }
            .overlay(alignment: .topTrailing) { menu(i).padding(10).environment(\.colorScheme, scheme) }
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .containerRelativeFrame(.horizontal) { w, _ in w - 28 } // w는 좌우 여백 16을 뺀 폭, 다음 장이 보이게
            .id(i)
    }

    @ViewBuilder private var stillPage: some View {
        if let still = still ?? DayStill.cached(day) {
            Image(uiImage: still).resizable().scaledToFill()
                .accessibilityLabel("\(title) \(resort) 경로 3D 그림")
                .accessibilityAddTraits(.isImage)
        } else {
            ZStack {
                Self.teal
                Image(systemName: "mountain.2.fill").font(.system(size: 160))
                    .foregroundStyle(.white.opacity(0.07)).offset(y: 50)
                    .accessibilityHidden(true)
                if stillDone {
                    // 그림을 만들지 못하면 리조트 이름만
                    Text(resort).font(.title2.weight(.bold)).foregroundStyle(.white).padding(.bottom, 64)
                } else {
                    ProgressView().tint(.white).padding(.bottom, 64)
                        .accessibilityLabel("3D 그림 만드는 중")
                }
            }
        }
    }

    @ViewBuilder private var photoPage: some View {
        if let photo {
            Image(uiImage: photo).resizable().scaledToFill()
                .overlay { // 아래 45% 어둡게
                    LinearGradient(stops: [.init(color: .clear, location: 0.55), .init(color: .black.opacity(0.55), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .accessibilityElement()
                .accessibilityLabel("\(title) \(resort) 사진")
                .accessibilityAddTraits(.isImage)
        } else {
            Button(action: pickPhoto) {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(Color.onAccent)
                        .frame(width: 52, height: 52).background(Color.accentFill, in: Circle())
                        .accessibilityHidden(true)
                    Text("이날 사진 붙이기").font(.body.weight(.semibold)).foregroundStyle(Color.accentText)
                    Text("한 장 · 이 기기에만 저장돼요").font(.footnote).foregroundStyle(Color.secondaryText)
                }
                .padding(.bottom, 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.card)
                .overlay(RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(Color.cardBorder, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 아래 유리 띠 → S6
    private var caption: some View {
        NavigationLink { DayDetailView(db: db, day: day) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(([resort] + (session.isEmpty ? [] : [session])).joined(separator: " · ")).font(.subheadline.weight(.semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(day.runs.count)회").font(.title2.weight(.bold))
                        Text("· " + km).font(.body)
                    }
                    .monospacedDigit()
                }
                Spacer(minLength: 4)
                Text("기록 보기 ›").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.primaryText)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(minHeight: 64)
            .modifier(GlassStrip())
            .padding(10)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(resort) \(session) \(day.runs.count)회 \(km), 기록 보기")
            .accessibilityAddTraits(.isButton)
        }
        .buttonStyle(.plain)
    }

    private var session: String { RecordFormat.sessionNames(day) }
    private var km: String { RecordFormat.km(day.runs.reduce(0) { $0 + $1.distance }) }

    private func menu(_ i: Int) -> some View {
        let k = kind(i)
        return Menu {
            Section {
                Button { share(k) } label: {
                    Label { Text("이미지로 공유")
                        Text(k == .photo ? "이 사진 위 오늘 요약" : k == .threeD ? "이 3D 그림 위 오늘 요약" : "2D 지도 위 오늘 요약")
                    } icon: { Image(systemName: "square.and.arrow.up") }
                }
                if k == .map, lock == .ticket {
                    Button { showTicket = true } label: { Label("이용권: 3D 그림으로 공유", systemImage: "lock") }
                }
            }
            if photo == nil {
                Button("사진 붙이기", systemImage: "photo.badge.plus") { showPhoto = true; pickPhoto() }
            } else {
                Button("사진 바꾸기", systemImage: "photo") { showPhoto = true; pickPhoto() }
                Button("사진 빼기", systemImage: "minus.circle", action: removePhoto)
            }
            Button("기록 지우기", systemImage: "trash", role: .destructive, action: delete)
        } label: {
            Group {
                if sharing { ProgressView() } else { Image(systemName: "ellipsis").font(.body.weight(.bold)) }
            }
            .frame(width: 44, height: 44)
            .modifier(MenuCircle())
        }
        .disabled(sharing)
        .accessibilityLabel(sharing ? "공유 이미지 만드는 중" : "\(resort) 기록 더 보기")
    }
}

/// 유리 띠 (iOS 26). 17.6~25는 흐린 재질
private struct GlassStrip: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

/// ⋯ 원: 그림 위라 17.6~25에서도 흐린 재질 원을 깐다
private struct MenuCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassCircle()
        } else {
            content.foregroundStyle(Color.primaryText).background(.ultraThinMaterial, in: Circle())
        }
    }
}
