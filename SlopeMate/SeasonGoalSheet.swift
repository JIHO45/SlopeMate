import SwiftUI

/// S9 목표 줄을 누르면 여는 시즌 목표 시트 (R36 v1). 내용 높이 시트, 가장 큰 글씨에서는 큰 시트에 저장 버튼 아래 고정.
struct SeasonGoalSheet: View {
    let season: String
    /// 지금 방문일·하강 횟수 (S9 합계와 같은 값)
    let visitDays: Int
    let runs: Int
    /// 고칠 때 기존 목표
    let initial: SeasonGoal?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var daysOn: Bool
    @State private var runsOn: Bool
    @State private var days: Int
    @State private var runCount: Int
    @State private var height: CGFloat = 480

    init(season: String, visitDays: Int, runs: Int, initial: SeasonGoal?) {
        self.season = season; self.visitDays = visitDays; self.runs = runs; self.initial = initial
        _daysOn = State(initialValue: initial == nil || initial?.days != nil)
        _runsOn = State(initialValue: initial == nil || initial?.runs != nil)
        _days = State(initialValue: initial?.days ?? SeasonGoal.defaultDays)
        _runCount = State(initialValue: initial?.runs ?? SeasonGoal.defaultRuns)
    }

    private var big: Bool { typeSize.isAccessibilitySize }
    private var canSave: Bool { daysOn || runsOn }

    var body: some View {
        Group {
            if big {
                ScrollView { form }
                    .safeAreaInset(edge: .bottom) {
                        saveButton
                            .padding(.horizontal, 16).padding(.top, 12)
                            .padding(.bottom, 8)
                            .background(alignment: .top) {
                                Color.bg.ignoresSafeArea(edges: .bottom).overlay(alignment: .top) { Divider().overlay(Color.cardBorder) }
                            }
                    }
                    .presentationDetents([.large])
            } else {
                VStack(spacing: 0) {
                    form
                    saveButton.padding(.horizontal, 16).padding(.top, 16)
                    if initial != nil { clearButton.padding(.top, 4) }
                }
                .padding(.bottom, 8)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .frame(maxHeight: .infinity, alignment: .top)
                .presentationDetents([.height(height)])
            }
        }
        .foregroundStyle(Color.primaryText)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .presentationBackground(Color.bg)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: big ? .top : .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(initial == nil ? "시즌 목표 정하기" : "시즌 목표 고치기").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(big ? "하나만 정해도 돼요" : "\(season) 시즌 · 하나만 정해도 돼요").font(.subheadline).foregroundStyle(Color.secondaryText)
                }
                .padding(.leading, 4)
                Spacer(minLength: 0)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .frame(width: big ? 56 : 44, height: big ? 56 : 44).glassCircle()
                }
                .buttonStyle(.plain).accessibilityLabel("취소")
            }
            VStack(spacing: 12) {
                goalCard("방문일", unit: "일", now: visitDays, on: $daysOn, value: $days, step: SeasonGoal.dayStep, max: SeasonGoal.maxDays)
                goalCard("하강 횟수", unit: "회", now: runs, on: $runsOn, value: $runCount, step: SeasonGoal.runStep, max: SeasonGoal.maxRuns)
            }
            .padding(.top, 16)
            Text("목표는 이 기기에만 저장돼요. 시즌이 바뀌면 새로 정해요.")
                .font(.footnote).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4).padding(.top, 12)
            if big, initial != nil { clearButton.padding(.top, 16) }
        }
        .padding(.horizontal, 16).padding(.top, 20)
    }

    private var clearButton: some View {
        Button("목표 지우기", role: .destructive) { SeasonGoal.save(nil, season: HomeData.currentSeason()); dismiss() }
            .foregroundStyle(Color(light: 0x8A1C1C, dark: 0xFFB4B4))
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    /// 저장할 때 이번 시즌을 다시 읽는다.
    private var saveButton: some View {
        Button("저장") {
            SeasonGoal.save(SeasonGoal(days: daysOn ? days : nil, runs: runsOn ? runCount : nil), season: HomeData.currentSeason())
            dismiss()
        }
        .buttonStyle(PrimaryButtonStyle(minHeight: big ? 88 : 60))
        .disabled(!canSave).opacity(canSave ? 1 : 0.4)
    }

    private func goalCard(_ title: String, unit: String, now: Int, on: Binding<Bool>, value: Binding<Int>, step: Int, max: Int) -> some View {
        let size: CGFloat = big ? 64 : 44
        return VStack(spacing: 12) {
            Toggle(isOn: on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(on.wrappedValue ? "지금 \(now)\(unit)" : "정하지 않음").font(.footnote).foregroundStyle(Color.secondaryText).monospacedDigit()
                }
            }
            .tint(Color.accentFill)
            .accessibilityLabel("\(title) 목표 쓰기")
            .accessibilityValue("지금 \(now)\(unit)")
            .frame(minHeight: 44)
            HStack(spacing: 8) {
                stepButton("minus", "\(title) 줄이기", size: size, disabled: value.wrappedValue <= 1) {
                    value.wrappedValue = SeasonGoal.step(value.wrappedValue, up: false, by: step, max: max)
                }
                (Text("\(value.wrappedValue)").font(.title2.bold()) + Text(unit).font(.callout.weight(.semibold)))
                    .foregroundStyle(Color.accentText).monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                stepButton("plus", "\(title) 늘리기", size: size, disabled: value.wrappedValue >= max) {
                    value.wrappedValue = SeasonGoal.step(value.wrappedValue, up: true, by: step, max: max)
                }
            }
            .padding(4)
            .background(Color.surface, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) 목표")
            .accessibilityValue("\(value.wrappedValue)\(unit)")
            .accessibilityAdjustableAction { d in
                value.wrappedValue = SeasonGoal.step(value.wrappedValue, up: d == .increment, by: step, max: max)
            }
            .disabled(!on.wrappedValue).opacity(on.wrappedValue ? 1 : 0.4)
        }
        .padding(.horizontal, 16).padding(.vertical, big ? 16 : 14)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
    }

    private func stepButton(_ icon: String, _ label: String, size: CGFloat, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .frame(width: size, height: size)
                .background(Color.card, in: Circle())
                .overlay(Circle().strokeBorder(Color.cardBorder))
        }
        .buttonStyle(.plain).buttonRepeatBehavior(.enabled)
        .disabled(disabled).opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(label)
    }
}
