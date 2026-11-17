import SwiftUI

/// S19 속도·고도 그래프 (R52, L). 가로는 실제 시각 비례(끊긴 구간도 그 길이만큼), 전체는 옅게, 지나온 부분은 진하게, 지금 위치 세로선 + 점.
/// "기록 없음" 구간은 선을 잇지 않고 점선 상자. 머리줄(제목 + 오른쪽 글)과 꼬리표까지 한 카드 안의 한 덩어리
struct RunChart: View {
    enum Kind { case speed, altitude }
    let kind: Kind
    let series: RunDetail.Series
    /// nil: 재생 전. 전체를 진하게, 세로선 없음
    let now: Date?
    /// 머리줄 오른쪽 ("최고 61 · 평균 43", "기록 없음 10:38~10:39", "1,340m → 928m")
    let note: String
    @Environment(\.dynamicTypeSize) private var typeSize

    init(kind: Kind, series: RunDetail.Series, now: Date?, note: String) {
        (self.kind, self.series, self.now, self.note) = (kind, series, now, note)
    }

    private var title: String { kind == .speed ? "속도 km/h" : "고도 m" }

    /// 그래프 단위 값(km/h·m)
    private func values(_ p: RunDetail.Piece) -> [RunDetail.Value] {
        kind == .speed ? p.speed.map { .init(t: $0.t, v: $0.v * 3.6) } : p.altitude
    }
    private func value(at t: Date) -> Double? {
        kind == .speed ? series.speed(at: t).map { $0 * 3.6 } : series.altitude(at: t)
    }

    /// 세로 범위와 눈금. 속도: 0부터 (최고·마지막 눈금 중 큰 값)×1.2. 고도: 최저·중간·최고 3줄
    private var scale: (lo: Double, hi: Double, ticks: [Double]) {
        if kind == .speed {
            let top = series.pieces.flatMap(\.speed).map(\.v).max().map { $0 * 3.6 } ?? 0
            let ticks = RunDetail.speedTicks(max: top)
            return (0, max(max(top, ticks.last ?? 0) * 1.2, 10), ticks)
        }
        guard let r = series.altitudeRange else { return (0, 1, []) }
        // 최저는 아래에서 6, 최고는 위에서 8 떨어진 자리(시안)
        let span = max(r.upperBound - r.lowerBound, 1)
        return (r.lowerBound - span * 0.07, r.upperBound + span * 0.1, [r.lowerBound, (r.lowerBound + r.upperBound) / 2, r.upperBound])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Canvas { ctx, size in draw(&ctx, size) }
                .frame(height: 124)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // 그림 안 글자
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityValue(note)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityHint(kind == .altitude && series.lowAccuracy ? "고도 정확도 낮음. 동작 권한이 없거나 기압계를 쓸 수 없어 GPS 고도로 판정했어요" : "")
    }

    /// 큰 글씨에서는 두 줄로 쌓는다
    private var header: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Text(title).font(.subheadline.weight(.semibold))
            if kind == .altitude, series.lowAccuracy { LowAccuracyTag() }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text(note).font(.footnote).foregroundStyle(Color.secondaryText).monospacedDigit()
        }
    }

    private var a11yLabel: String {
        var s = kind == .speed ? "속도 그래프" : "고도 그래프"
        if !series.gaps.isEmpty { s += ", 기록 없음 구간은 비어 있음" }
        if let now, let v = value(at: now) { s += ", 지금 \(kind == .speed ? "\(Int(v.rounded()))km/h" : "\(Int(v.rounded()).formatted())m")" }
        return s
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let (lo, hi, ticks) = scale
        let font = Font.caption2.monospacedDigit()
        func label(_ s: String) -> GraphicsContext.ResolvedText {
            ctx.resolve(Text(s).font(font).foregroundStyle(Color.secondaryText))
        }
        let tickTexts = ticks.map { label(Int($0.rounded()).formatted()) }
        // 속도·고도 그래프의 가로축이 같은 자리에 오게 왼쪽 폭은 고정 글("8,888")로 잰다
        let left = label("8,888").measure(in: size).width + 6
        let startText = label(RecordFormat.time(series.start)), endText = label(RecordFormat.time(series.end))
        let timeH = startText.measure(in: size).height
        let plot = CGRect(x: left, y: 6, width: max(1, size.width - left - 4), height: max(1, size.height - 6 - timeH - 6))
        func x(_ t: Date) -> CGFloat { plot.minX + CGFloat(series.x(t)) * plot.width }
        func y(_ v: Double) -> CGFloat { plot.maxY - CGFloat((v - lo) / max(hi - lo, 1e-9)) * plot.height }

        // 가로 눈금과 왼쪽 숫자
        for (v, text) in zip(ticks, tickTexts) {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(v)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(v)))
            ctx.stroke(line, with: .color(.chartLine), lineWidth: 1)
            ctx.draw(text, at: CGPoint(x: plot.minX - 6, y: y(v)), anchor: .trailing)
        }
        ctx.draw(startText, at: CGPoint(x: plot.minX, y: size.height), anchor: .bottomLeading)
        ctx.draw(endText, at: CGPoint(x: plot.maxX, y: size.height), anchor: .bottomTrailing)

        // 기록 없음: 점선 상자 + 가운데 아래 글(자리가 있을 때만)
        for g in series.gaps {
            let r = CGRect(x: x(g.start), y: plot.minY + 4, width: max(1, x(g.end) - x(g.start)), height: plot.maxY - plot.minY - 4)
            ctx.stroke(Path(r), with: .color(.secondaryText), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let t = label("기록 없음")
            if t.measure(in: size).width + 4 < r.width { ctx.draw(t, at: CGPoint(x: r.midX, y: r.maxY - 2), anchor: .bottom) }
        }

        // 조각마다 선. 지나온 부분은 now의 보간 값까지
        for piece in series.pieces {
            let vs = values(piece)
            guard vs.count > 1 else { continue }
            let all = vs.map { CGPoint(x: x($0.t), y: y($0.v)) }
            var past = all
            if let now {
                past = vs.filter { $0.t <= now }.map { CGPoint(x: x($0.t), y: y($0.v)) }
                if let last = vs.last, let first = vs.first, first.t < now, now < last.t, let v = value(at: now) {
                    past.append(CGPoint(x: x(now), y: y(v)))
                }
                ctx.stroke(polyline(all), with: .color(.accentText.opacity(0.3)), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            guard past.count > 1 else { continue }
            if kind == .altitude {
                var fill = polyline(past)
                fill.addLine(to: CGPoint(x: past.last!.x, y: plot.maxY))
                fill.addLine(to: CGPoint(x: past[0].x, y: plot.maxY))
                fill.closeSubpath()
                ctx.fill(fill, with: .color(.surface))
            }
            ctx.stroke(polyline(past), with: .color(.accentText), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }

        // 지금 위치
        if let now {
            var line = Path()
            line.move(to: CGPoint(x: x(now), y: 0))
            line.addLine(to: CGPoint(x: x(now), y: plot.maxY))
            ctx.stroke(line, with: .color(.primaryText.opacity(0.45)), lineWidth: 1)
            if let v = value(at: now) {
                let p = CGPoint(x: x(now), y: y(v))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(.accentFill.opacity(0.25)))
                let dot = Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
                ctx.fill(dot, with: .color(.card))
                ctx.stroke(dot, with: .color(.accentText), lineWidth: 2.5)
            }
        }
    }
}

/// 이번 시즌 이 슬로프: 하강마다 최고(실선, 강조색)·평균(점선, 보조색), 보고 있는 하강 자리에 세로선과 점, 오른쪽에 그 값.
/// 1번뿐이면 그래프 없이 한 줄
struct RunHistoryChart: View {
    let history: RunDetail.History
    @Environment(\.dynamicTypeSize) private var typeSize

    init(history: RunDetail.History) { self.history = history }

    private func kmh(_ v: Double) -> Int { Int((v * 3.6).rounded()) }
    private var k: Int { history.index + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Text("이번 시즌 이 슬로프").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text(history.count == 1 ? "1번째" : "\(history.count)번 중 \(k)번째")
                    .font(.footnote).foregroundStyle(Color.secondaryText).monospacedDigit()
            }
            if history.count == 1 {
                Text("이번 시즌 이 슬로프 첫 기록이에요").font(.footnote).foregroundStyle(Color.secondaryText)
            } else {
                Canvas { ctx, size in draw(&ctx, size) }
                    .frame(height: 100)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .accessibilityElement()
                    .accessibilityLabel(a11yLabel)
                Text(summary).font(.footnote).foregroundStyle(Color.secondaryText).monospacedDigit()
            }
        }
    }

    /// "시즌 최고 64km/h (7번째) · 첫 번째보다 최고 +9km/h". 첫 번째를 보고 있으면 앞부분만
    private var summary: String {
        let best = history.maxSpeeds[history.bestIndex]
        var s = "시즌 최고 \(kmh(best))km/h (\(history.bestIndex + 1)번째)"
        if history.index > 0 {
            let d = kmh(history.maxSpeeds[history.index]) - kmh(history.maxSpeeds[0])
            s += " · 첫 번째보다 최고 \(d >= 0 ? "+" : "−")\(abs(d))km/h"
        }
        return s
    }

    private var a11yLabel: String {
        let m = history.maxSpeeds.map(kmh), a = history.avgSpeeds.map(kmh)
        return "이 슬로프 \(history.count)번의 최고 속도와 평균 속도 변화. 최고 \(m.first!)에서 \(m.last!)km/h, 평균 \(a.first!)에서 \(a.last!)km/h. "
            + "이번은 \(k)번째, 최고 \(m[history.index])km/h, 평균 \(a[history.index])km/h"
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let maxs = history.maxSpeeds.map { $0 * 3.6 }, avgs = history.avgSpeeds.map { $0 * 3.6 }
        let font = Font.caption2.monospacedDigit()
        let maxLabel = ctx.resolve(Text("최고 \(Int(maxs[history.index].rounded()))").font(font.weight(.semibold)).foregroundStyle(Color.accentText))
        let avgLabel = ctx.resolve(Text("평균 \(Int(avgs[history.index].rounded()))").font(font).foregroundStyle(Color.secondaryText))
        let right = max(maxLabel.measure(in: size).width, avgLabel.measure(in: size).width) + 10
        let first = ctx.resolve(Text("1번째").font(font).foregroundStyle(Color.secondaryText))
        let labelH = first.measure(in: size).height
        let plot = CGRect(x: 12, y: 10, width: max(1, size.width - 12 - right), height: max(1, size.height - 10 - labelH - 10))
        let lo = min(0, avgs.min() ?? 0), hi = max(maxs.max() ?? 1, 1) * 1.1
        let n = maxs.count
        func x(_ i: Int) -> CGFloat { plot.minX + plot.width * CGFloat(i) / CGFloat(max(n - 1, 1)) }
        func y(_ v: Double) -> CGFloat { plot.maxY - CGFloat((v - lo) / (hi - lo)) * plot.height }

        var base = Path()
        base.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        base.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        ctx.stroke(base, with: .color(.chartLine), lineWidth: 1)
        // 보고 있는 하강 자리
        let cx = x(history.index)
        if history.index < n - 1 {
            var mark = Path()
            mark.move(to: CGPoint(x: cx, y: plot.minY - 6))
            mark.addLine(to: CGPoint(x: cx, y: plot.maxY))
            ctx.stroke(mark, with: .color(.primaryText.opacity(0.3)), lineWidth: 1)
        }
        ctx.stroke(polyline(avgs.indices.map { CGPoint(x: x($0), y: y(avgs[$0])) }), with: .color(.secondaryText),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 4]))
        ctx.stroke(polyline(maxs.indices.map { CGPoint(x: x($0), y: y(maxs[$0])) }), with: .color(.accentText),
                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        let pm = CGPoint(x: cx, y: y(maxs[history.index])), pa = CGPoint(x: cx, y: y(avgs[history.index]))
        ctx.fill(Path(ellipseIn: CGRect(x: pm.x - 4, y: pm.y - 4, width: 8, height: 8)), with: .color(.accentText))
        ctx.fill(Path(ellipseIn: CGRect(x: pa.x - 3.5, y: pa.y - 3.5, width: 7, height: 7)), with: .color(.secondaryText))
        // 오른쪽 값: 이번 하강. 두 글이 겹치지 않게
        let lh = labelH + 2
        let ym = min(pm.y, max(pa.y, pm.y) - lh), ya = max(pa.y, ym + lh)
        ctx.draw(maxLabel, at: CGPoint(x: plot.maxX + 10, y: ym), anchor: .leading)
        ctx.draw(avgLabel, at: CGPoint(x: plot.maxX + 10, y: ya), anchor: .leading)
        // 아래: 1번째 … n번째, 보고 있는 자리에 "이번"
        let current = ctx.resolve(Text("이번").font(font.weight(.semibold)).foregroundStyle(Color.accentText))
        let last = ctx.resolve(Text("\(n)번째").font(font).foregroundStyle(Color.secondaryText))
        let cw = current.measure(in: size).width, fw = first.measure(in: size).width, lw = last.measure(in: size).width
        let cxl = min(max(cx, plot.minX + cw / 2), plot.maxX - cw / 2)
        if history.index > 0, cxl - cw / 2 > plot.minX + fw + 4 || history.index == n - 1 {
            ctx.draw(first, at: CGPoint(x: plot.minX, y: size.height), anchor: .bottomLeading)
        }
        if history.index < n - 1, cxl + cw / 2 < plot.maxX - lw - 4 {
            ctx.draw(last, at: CGPoint(x: plot.maxX, y: size.height), anchor: .bottomTrailing)
        }
        ctx.draw(current, at: CGPoint(x: cxl, y: size.height), anchor: .bottom)
    }
}

/// "고도 정확도 낮음" 꼬리표 (DaySummary와 같은 모양)
struct LowAccuracyTag: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(light: 0xA87400, dark: 0xF2B92E))
            Text("고도 정확도 낮음").foregroundStyle(Color.primaryText)
        }
        .font(.footnote)
        .padding(.vertical, 3).padding(.leading, 8).padding(.trailing, 10)
        .background(Color.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.cardBorder))
    }
}

private func polyline(_ pts: [CGPoint]) -> Path {
    var p = Path()
    p.addLines(pts)
    return p
}

extension Color {
    /// 카드 안 구분선·그래프 눈금 (확정 시안 #E3ECEF / #23404B, DayDetailView와 같은 값)
    static let chartLine = Color(light: 0xE3ECEF, dark: 0x23404B)
}
