import SwiftUI

/// 내 리프트 대기 (R32, 확정 v2). S6 줄에서는 그날 리프트별, S9 카드에서는 시즌 리조트별·리프트별.
struct LiftWaitView: View {
    /// "11월 29일 · 하이원" 또는 "2026-27 시즌"
    let caption: String
    let summary: LiftWaitStats.Summary
    var byResort = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(caption).font(.subheadline).foregroundStyle(Color.secondaryText)
                    Text(RecordFormat.duration(summary.total)).font(.largeTitle.bold()).monospacedDigit().foregroundStyle(Color.accentText)
                    Text(Self.countLine(summary.count, avg: summary.avg)).font(.subheadline).foregroundStyle(Color.secondaryText).monospacedDigit()
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)

                if byResort {
                    ForEach(resorts, id: \.id) { r in
                        HStack {
                            Text(Resort.name(r.id)).fontWeight(.semibold)
                            Spacer()
                            Text("\(RecordFormat.duration(r.total)) · \(r.count)회").foregroundStyle(Color.secondaryText)
                        }
                        .font(.subheadline).monospacedDigit()
                        .padding(.horizontal, 4).padding(.top, 20).padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                        card(r.lifts)
                    }
                } else {
                    card(summary.lifts).padding(.top, 20)
                }

                Text("탑승장 근처에 온 뒤 탈 때까지 머문 시간이에요. 일행을 기다린 시간도 들어가요. 리프트를 알아보지 못한 탑승은 빠져요.")
                    .font(.footnote).foregroundStyle(Color.secondaryText)
                    .padding(.horizontal, 4).padding(.top, 12)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
        }
        .background(Color.bg)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("리프트 대기")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 리조트 묶음: 합계가 긴 순, 안의 리프트도 긴 순(summary.lifts 순서 유지)
    private struct ResortGroup { var id: String, count: Int, total: Double, lifts: [LiftWaitStats.Lift] }

    private var resorts: [ResortGroup] {
        let groups = Dictionary(grouping: summary.lifts, by: \.resortId).map { id, lifts in
            ResortGroup(id: id, count: lifts.reduce(0) { $0 + $1.count }, total: lifts.reduce(0) { $0 + $1.total }, lifts: lifts)
        }
        return groups.sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id }
    }

    private func card(_ lifts: [LiftWaitStats.Lift]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(lifts.enumerated()), id: \.offset) { i, l in
                if i > 0 { Color.rowDivider.frame(height: 1) }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.liftName(l)).font(.body.weight(.semibold))
                        Text(l.count > 1 ? "\(l.count)회 · 평균 \(RecordFormat.duration(l.avg))" : "1회")
                            .font(.footnote).foregroundStyle(Color.secondaryText).monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    Text(RecordFormat.duration(l.total)).font(.body.weight(.semibold)).monospacedDigit()
                }
                .padding(.horizontal, 16).frame(minHeight: 60)
                .accessibilityElement(children: .combine)
            }
        }
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
    }

    /// "탑승 6회 · 한 번에 평균 8분" (한 번이면 평균 없이)
    static func countLine(_ count: Int, avg: Double) -> String {
        count > 1 ? "탑승 \(count)회 · 한 번에 평균 \(RecordFormat.duration(avg))" : "탑승 \(count)회"
    }

    /// 지도(OSM)의 리프트 이름. 없으면 "이름 없는 리프트"
    static func liftName(_ l: LiftWaitStats.Lift) -> String {
        SlopeMap.cached(resortId: l.resortId)?.lifts.first { $0.id == l.liftId }?.name ?? "이름 없는 리프트"
    }
}

/// S6 시트 합계 아래 한 줄 (R32 v2). 잠겨 있으면 숫자 대신 자물쇠 "이용권"
struct LiftWaitRow: View {
    let summary: LiftWaitStats.Summary
    let locked: Bool

    var body: some View {
        HStack(spacing: 10) {
            LiftIcon().foregroundStyle(Color.accentText)
            Text("리프트 대기").fontWeight(.semibold)
            Spacer(minLength: 8)
            if locked {
                Label("이용권", systemImage: "lock.fill").font(.footnote).foregroundStyle(Color.secondaryText)
            } else {
                Text("\(summary.count)회 · ").foregroundStyle(Color.secondaryText) + Text(RecordFormat.duration(summary.total)).fontWeight(.semibold)
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText).accessibilityHidden(true)
        }
        .font(.subheadline).monospacedDigit().foregroundStyle(Color.primaryText)
        .padding(.horizontal, 14).frame(minHeight: 52)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(locked ? "리프트 대기, 시즌 이용권 필요" : "리프트 대기 \(RecordFormat.duration(summary.total)), 리프트별 보기")
        .accessibilityAddTraits(.isButton)
    }
}
