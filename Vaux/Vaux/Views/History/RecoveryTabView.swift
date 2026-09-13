// RecoveryTabView.swift
// Vaux
//
// Every chart carries a reference: HRV over the athlete's own range with the
// training load beneath; HRV by block week; resting HR against its range;
// sleep against a 7:30 need; weight as daily dots, 7-day line, weekly means.

import SwiftUI

struct RecoveryTabView: View {
    let vm: RecoveryInsightsViewModel
    let calendar: BlockCalendar
    @Binding var tab: HistoryView.Tab
    let askCoach: (String) -> Void
    let onRangeChange: () -> Void

    @State private var rangeLabel: String = RecoveryInsightsViewModel.Window.d30.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            DiagnosisText(text: RecoveryInsightsViewModel.diagnosis(vm), coachPrompt: RecoveryInsightsViewModel.coachPrompt(vm), askCoach: askCoach)
            HStack {
                RangeChips(options: RecoveryInsightsViewModel.Window.allCases.map(\.rawValue), selected: $rangeLabel)
                Spacer()
                EditorialEyebrow(text: vm.isAggregated ? "WEEKLY MEANS" : "PEAK · DELOAD SHADED", color: Editorial.muted, size: 10, kerning: 1.5)
            }
            .padding(.horizontal, Editorial.gutter).padding(.top, 4).padding(.bottom, 12)
            .onChange(of: rangeLabel) { _, new in
                if let r = RecoveryInsightsViewModel.Window(rawValue: new) { vm.range = r; onRangeChange() }
            }
            if vm.isLoading && vm.history.isEmpty {
                ProgressView().tint(Editorial.mid).frame(maxWidth: .infinity).padding(.vertical, 30)
            }
            if !vm.weekGroups.isEmpty && !vm.isAggregated { hrvByWeek }
            restingHR
            sleep
            weight
        }
    }

    // MARK: Hero

    private var hero: some View {
        HeroPanel(height: 690) {
            VStack(alignment: .leading, spacing: 0) {
                HeroTopBar(left: "RECOVERY", right: "LAST \(vm.range.days) DAYS · \(calendar.current.blockLabel)")
                HistoryTabChips(selected: $tab).padding(.top, 14)
                // Today's reading in every window. The aggregated chart's last
                // slot is a weekly mean, and the headline once followed it: 90D
                // read 42 where 30D read 50 for the same morning.
                EditorialEyebrow(text: "HRV · TODAY", color: Editorial.lime, size: 10, kerning: 2.5).padding(.top, 18)
                HStack(alignment: .bottom) {
                    if let v = vm.hrvLatest {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            CountUpFigure(value: v, size: 132)
                            Text("MS").font(.display(56)).foregroundStyle(Editorial.lime)
                        }
                    } else {
                        Text("—").font(.display(132)).foregroundStyle(Editorial.muted)
                    }
                    Spacer()
                    StatStack(lines: statLines).padding(.bottom, 10)
                }
                .frame(height: 124)
                DotBandChart(values: vm.hrv.values, color: Editorial.lime, band: vm.hrv.band, badBelow: true,
                             shadedSlots: vm.hrv.slots { $0.block == calendar.current.block && ($0.isPeak || $0.isDeload) },
                             range: vm.hrv.range, ticks: ticks(for: vm.hrv.range))
                    .frame(height: 220)
                    .padding(.horizontal, -Editorial.gutter)
                    .padding(.top, 8)
                if !vm.isAggregated {
                    LoadStrip(tonnage: vm.loadTonnage, legs: vm.loadIsLegs)
                        .frame(height: 30)
                        .padding(.horizontal, -Editorial.gutter)
                        .padding(.top, 6)
                }
                weekAxis(vm.hrv).padding(.top, 6)
                HStack {
                    EditorialEyebrow(text: vm.hrv.band == nil ? "LINE = 7-DAY AVG" : "SHADED = YOUR RANGE · LINE = 7-DAY AVG", color: Editorial.muted, size: 9, kerning: 1.5)
                    Spacer()
                    if !vm.isAggregated { EditorialEyebrow(text: "▮ LEGS", color: Editorial.lime, size: 9, kerning: 1.5) }
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, Editorial.gutter)
            .padding(.top, 58)
        }
    }

    private var statLines: [StatStack.Line] {
        var lines: [StatStack.Line] = []
        if let b = vm.hrvBand { lines.append(.init(text: "YOUR RANGE \(Int(b.lowerBound.rounded()))–\(Int(b.upperBound.rounded()))")) }
        if let a = vm.hrvAvg7 { lines.append(.init(text: "7-DAY AVG \(Int(a.rounded()))")) }
        if vm.hrvBand != nil {
            let n = vm.hrvBelowLast10
            lines.append(.init(text: "\(n) OF LAST 10 DAYS BELOW", color: n >= 4 ? Editorial.amber : Editorial.mid))
        } else if let r = vm.rhrLatest {
            lines.append(.init(text: "RHR \(Int(r))"))
        }
        return lines.isEmpty ? [.init(text: "NO READINGS", color: Editorial.muted)] : lines
    }

    private func ticks(for r: ClosedRange<Double>) -> [Double] {
        let span = r.upperBound - r.lowerBound
        let step: Double = span > 40 ? 20 : (span > 16 ? 10 : (span > 6 ? 5 : 2))
        var t: [Double] = []
        var v = (r.lowerBound / step).rounded(.up) * step
        while v <= r.upperBound { t.append(v); v += step }
        return t
    }

    /// Axis labels where the block position changes. Daily windows label
    /// each week; aggregated windows, where every slot is already a week,
    /// label only where the BLOCK changes — labelling every week there
    /// stacked twelve strings into one unreadable smear.
    private func weekAxis(_ s: RecoverySeries) -> some View {
        GeometryReader { geo in
            let n = max(1, s.values.count)
            let step = n > 1 ? (geo.size.width - 40) / CGFloat(n - 1) : 0
            let minGap: CGFloat = 46
            ZStack(alignment: .topLeading) {
                ForEach(Array(axisLabels(s, step: step, minGap: minGap).enumerated()), id: \.offset) { _, item in
                    Text(item.text).font(.system(size: 9, weight: .bold)).kerning(1.5)
                        .foregroundStyle(item.now ? Editorial.lime : Editorial.muted)
                        .fixedSize()
                        .offset(x: CGFloat(item.slot) * step)
                }
            }
        }
        .frame(height: 14)
    }

    private func axisLabels(_ s: RecoverySeries, step: CGFloat, minGap: CGFloat) -> [(slot: Int, text: String, now: Bool)] {
        var out: [(slot: Int, text: String, now: Bool)] = []
        var lastX: CGFloat = -.infinity
        for i in 0..<s.positions.count {
            guard let p = s.positions[i] else { continue }
            let prev = i > 0 ? s.positions[i - 1] : nil
            let changed = vm.isAggregated ? (prev?.block != p.block) : (prev != p)
            guard i == 0 || changed else { continue }
            let x = CGFloat(i) * step
            let isNow = p == calendar.current
            guard isNow || x - lastX >= minGap else { continue }
            let text: String
            if p.block == calendar.current.block {
                text = vm.isAggregated ? "NOW" : "W\(p.week)\(p.isPeak ? " PEAK" : "")"
            } else {
                text = vm.isAggregated ? p.shortBlockLabel : "\(p.shortBlockLabel)·W\(p.week)"
            }
            out.append((i, text, isNow || (vm.isAggregated && p.block == calendar.current.block)))
            lastX = x
        }
        return out
    }

    // MARK: Panels

    private var hrvByWeek: some View {
        let drop = vm.peakWeekHRVDrop
        let eyebrow = drop.map { $0 > 0 ? "MEAN FELL \(Int($0.rounded())) MS IN PEAK WEEK" : "PEAK WEEK HELD INSIDE RANGE" } ?? "BY BLOCK WEEK"
        let now = vm.weekGroups.last { $0.highlight }
        return PosterRow(eyebrow: eyebrow, eyebrowColor: (drop ?? 0) > 2 ? Editorial.amber : Editorial.muted, title: "HRV BY WEEK",
                         subtitle: "mean · min–max · shaded = your range",
                         value: now.flatMap { $0.values.isEmpty ? nil : String(Int(ChartMath.mean($0.values).rounded())) } ?? "—", unit: now == nil ? "" : "MS · NOW") {
            WeekRangeChart(groups: vm.weekGroups, band: vm.hrv.band, range: vm.hrv.range, color: Editorial.lime)
                .frame(height: 150).padding(.top, 6).padding(.bottom, 12)
        }
    }

    private var restingHR: some View {
        let above = vm.rhrAboveCount
        let eyebrow = vm.rhrBand == nil ? "RANGE NEEDS TWO WEEKS OF READINGS" : (above > 0 ? "\(above) OF LAST 10 DAYS ABOVE RANGE" : "INSIDE RANGE · LAST 10 DAYS")
        return PosterRow(eyebrow: eyebrow, eyebrowColor: above >= 4 ? Editorial.amber : Editorial.emerald, title: "RESTING HR",
                         subtitle: vm.rhrBand.map { "your range \(Int($0.lowerBound.rounded()))–\(Int($0.upperBound.rounded())) bpm · line = 7-day avg" } ?? "line = 7-day avg",
                         value: vm.rhrLatest.map { String(Int($0.rounded())) } ?? "—", unit: vm.rhrLatest == nil ? "" : "BPM") {
            DotBandChart(values: vm.rhr.values, color: Editorial.blue, band: vm.rhr.band, badBelow: false,
                         shadedSlots: vm.rhr.slots { $0.block == calendar.current.block && ($0.isPeak || $0.isDeload) },
                         range: vm.rhr.range, ticks: ticks(for: vm.rhr.range))
                .frame(height: 120).padding(.top, 6).padding(.bottom, 12)
        }
    }

    private var sleep: some View {
        let short = vm.shortNightsLast7
        let debt = vm.sleepDebtLast7
        // Short enough for one line: the old form truncated to "−4:3…".
        let eyebrow = short > 0 ? "\(short) SHORT NIGHT\(short == 1 ? "" : "S") · −\(SleepBarsChart.hm(debt)) THIS WK" : (debt > 0.25 ? "−\(SleepBarsChart.hm(debt)) DEBT THIS WK" : "NEED MET ALL WEEK")
        return PosterRow(eyebrow: eyebrow, eyebrowColor: short > 0 ? Editorial.amber : Editorial.emerald, title: "SLEEP",
                         subtitle: "bars = nights · line = 7:30 need",
                         value: vm.sleepLatest.map { SleepBarsChart.hm($0) } ?? "—", unit: vm.sleepLatest == nil ? "" : "HRS") {
            SleepBarsChart(hours: vm.sleep.values, shadedSlots: vm.sleep.slots { $0.block == calendar.current.block && ($0.isPeak || $0.isDeload) })
                .frame(height: 130).padding(.top, 6).padding(.bottom, 12)
        }
    }

    private var weight: some View {
        // First and last CALENDAR weeks of the window — the same chunks the
        // weekly-mean labels are drawn from — so the headline delta agrees
        // with the labels under it. Taking the first seven readings instead
        // reached past a gap into week two and read 2.9kg under labels that
        // ran 76.5 to 80.5.
        let slots = vm.weight.values
        let first7 = slots.prefix(7).compactMap { $0 }, last7 = slots.suffix(7).compactMap { $0 }
        let delta = (first7.isEmpty || last7.isEmpty) ? nil : ChartMath.mean(last7) - ChartMath.mean(first7)
        let eyebrow = delta.map { abs($0) < 0.3 ? "FLAT OVER THE WINDOW" : ($0 < 0 ? "▾ \(String(format: "%.1f", abs($0))) KG OVER THE WINDOW" : "▴ \(String(format: "%.1f", $0)) KG OVER THE WINDOW") } ?? "WEIGHT"
        // Muscle-gain phase: weight drifting DOWN is the thing to flag, not
        // to paint green. The cut is over; a 15kg fall over the whole history
        // read as an achievement on a page whose goal is the opposite.
        let eyebrowColor: Color = delta.map { $0 < -0.3 ? Editorial.amber : ($0 > 0.3 ? Editorial.emerald : Editorial.muted) } ?? Editorial.muted
        var labels: [(slot: Int, text: String)] = []
        var i = 0
        while i < vm.weight.values.count {
            let chunk = vm.weight.values[i..<min(i + 7, vm.weight.values.count)].compactMap { $0 }
            if !chunk.isEmpty { labels.append((slot: i + min(3, chunk.count - 1), text: String(format: "%.1f", ChartMath.mean(chunk)))) }
            i += 7
        }
        let weekLabels = vm.isAggregated ? [] : labels
        return PosterRow(eyebrow: eyebrow, eyebrowColor: eyebrowColor, title: "WEIGHT",
                         subtitle: "dots daily · line 7-day avg · weekly means",
                         value: vm.weightLatest.map { String(format: "%.1f", $0) } ?? "—", unit: vm.weightLatest == nil ? "" : "KG") {
            TrendDotsChart(values: vm.weight.values, color: Editorial.sand, weekLabels: weekLabels, range: vm.weight.range)
                .frame(height: 110).padding(.top, 6).padding(.bottom, 18)
        }
    }
}
