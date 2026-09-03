// StrengthTabView.swift
// Vaux
//
// Median gain and the muscle map as the hero; By Muscle (watch first); The
// Sheet (one ribbon per lift, deloads shaded, PRs as white dots); Balance.
// The hero scrubs between blocks and the map filters the sheet.

import SwiftUI

struct StrengthTabView: View {
    let vm: StrengthViewModel
    let calendar: BlockCalendar
    @Binding var tab: HistoryView.Tab
    let askCoach: (String) -> Void

    @State private var focus: BodyMuscle? = nil
    @State private var showAllLifts = false

    private var snap: BlockSnapshot? { vm.shown }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            DiagnosisText(text: StrengthViewModel.diagnosis(snap, focus: focus),
                          coachPrompt: StrengthViewModel.coachPrompt(snap, focus: focus),
                          askCoach: askCoach)
            if (snap?.judgedCount ?? 0) == 0 {
                NoReadNote(text: "A lift is judged once it has a peak-week best in two consecutive blocks. Sessions are stamped with their block week from now on, so the first full reading arrives at the end of the next peak week.")
            }
            byMuscle
            sheet
            balance
            Text("Est. 1RM is Epley on the best set of ≤\(StrengthViewModel.maxRepsForE1RM) reps. Each block is judged by its peak week; deload weeks are shaded and never count as a drop. Ribbons share one scale: ±8% around each lift's mean.")
                .font(.system(size: 11)).lineSpacing(3).foregroundStyle(Editorial.muted)
                .padding(.horizontal, Editorial.gutter).padding(.top, 18)
        }
    }

    // MARK: Hero

    private var hero: some View {
        HeroPanel(height: 790) {
            VStack(alignment: .leading, spacing: 0) {
                HeroTopBar(left: "STRENGTH", right: heroRight)
                HistoryTabChips(selected: $tab).padding(.top, 14)
                EditorialEyebrow(text: "MEDIAN STRENGTH GAIN · PEAK WEEK VS PEAK WEEK", color: Editorial.lime, size: 10, kerning: 2.5)
                    .padding(.top, 18)
                HStack(alignment: .bottom) {
                    if let g = snap?.medianGainPct {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(g < 0 ? "−" : "").font(.display(60)).foregroundStyle(Editorial.amber)
                            CountUpFigure(value: abs(g), decimals: 1, size: 132)
                            Text("%").font(.display(56)).foregroundStyle(Editorial.lime)
                        }
                    } else {
                        Text("—").font(.display(132)).foregroundStyle(Editorial.muted)
                    }
                    Spacer()
                    StatStack(lines: statLines).padding(.bottom, 10)
                }
                .frame(height: 124)
                scrubber.padding(.top, 8)
                BodyMapView(states: snap?.muscleStates ?? [:], selected: $focus)
                    .frame(height: 380)
                    .padding(.top, 10)
                StateLegend().padding(.top, 12)
            }
            .padding(.horizontal, Editorial.gutter)
            .padding(.top, 58)
        }
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { g in
                guard abs(g.translation.width) > abs(g.translation.height) else { return }
                if g.translation.width < 0 { step(1) } else { step(-1) }
            }
        )
    }

    private var heroRight: String {
        let p = calendar.current
        return "\(p.blockLabel) · WEEK \(p.week)"
    }

    private var statLines: [StatStack.Line] {
        guard let s = snap else { return [.init(text: "NO READ YET", color: Editorial.muted)] }
        if s.judgedCount == 0 { return [.init(text: "NO READ YET", color: Editorial.muted), .init(text: "\(s.muscles.filter { $0.state == .short }.count) SHORT ON SETS", color: Editorial.amber)] }
        return [
            .init(text: "\(s.upCount) OF \(s.judgedCount) LIFTS UP"),
            .init(text: "\(s.prCount) ALL-TIME PR\(s.prCount == 1 ? "" : "S")"),
            .init(text: "\(s.stalledCount) STALLED", color: s.stalledCount > 0 ? Editorial.amber : Editorial.mid),
        ]
    }

    private var scrubber: some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold)).frame(width: 34, height: 34) }
                .disabled(vm.shownIndex <= 0)
            Spacer()
            VStack(spacing: 5) {
                EditorialEyebrow(text: snap.map { s in s.dateRange.map { "\(s.judged.blockLabel) · \($0)" } ?? s.judged.blockLabel } ?? "", size: 10, kerning: 2)
                EditorialEyebrow(text: snap == nil ? "" : "JUDGED AT PEAK WEEK", color: Editorial.muted, size: 8.5, kerning: 1.5)
            }
            Spacer()
            Button { step(1) } label: { Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).frame(width: 34, height: 34) }
                .disabled(vm.shownIndex >= vm.snapshots.count - 1)
        }
        .foregroundStyle(Editorial.mid)
        .opacity(vm.snapshots.count > 1 ? 1 : 0.35)
    }

    private func step(_ d: Int) {
        let target = vm.shownIndex + d
        guard target >= 0, target < vm.snapshots.count else { return }
        Haptic.selection()
        withAnimation(Motion.smooth) { vm.shownIndex = target }
    }

    // MARK: By muscle

    private var byMuscle: some View {
        VStack(spacing: 0) {
            SectionBar(title: "BY MUSCLE", right: "WATCH FIRST · TAP FOR LIFTS")
            ForEach((snap?.muscles ?? []).sorted { a, b in
                if a.state.attention != b.state.attention { return a.state.attention < b.state.attention }
                return (a.drivingLift?.peak?.e1rm ?? 0) > (b.drivingLift?.peak?.e1rm ?? 0)
            }) { m in
                let lift = m.drivingLift
                let subtitle: String = {
                    var s = lift?.name.uppercased() ?? "NO LOADED LIFT"
                    if let d = lift?.deltaPct { s += "  " + Editorial.signedPct(d) }
                    s += "\n" + String(format: "%.1f sets/wk · band %d–%d", m.setsPerWeek, m.band.lowerBound, m.band.upperBound)
                    return s
                }()
                Button {
                    Haptic.selection()
                    withAnimation(Motion.snappy) { focus = (focus == m.muscle) ? nil : m.muscle }
                } label: {
                    PosterRow(eyebrow: m.stateLine, eyebrowColor: m.state.inkColor, title: m.muscle.rawValue,
                              subtitle: subtitle,
                              value: lift?.peak.map { String(Int($0.e1rm.rounded())) } ?? "—", unit: lift?.peak == nil ? "" : "KG",
                              valueColor: lift?.peak == nil ? Editorial.muted : .white)
                        .padding(.bottom, 18)
                        .background(focus == m.muscle ? Color.white.opacity(0.03) : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: The sheet

    private var visibleLifts: [LiftReport] {
        guard let s = snap else { return [] }
        var lifts = s.lifts
        if let focus { lifts = lifts.filter { $0.muscle == focus } }
        if !showAllLifts { lifts = lifts.filter { $0.state != StrengthState.none } }
        return lifts.sorted { a, b in
            if a.state.attention != b.state.attention { return a.state.attention < b.state.attention }
            return (a.peak?.e1rm ?? 0) > (b.peak?.e1rm ?? 0)
        }
    }

    private var sheet: some View {
        VStack(spacing: 0) {
            SectionBar(title: focus.map { "THE SHEET · \($0.rawValue.uppercased())" } ?? "THE SHEET",
                       right: "\(visibleLifts.count) LIFTS · 12 WEEKS")
            if visibleLifts.isEmpty {
                NoReadNote(text: focus == nil ? "No lift has two blocks of data yet." : "No judged lift for this muscle yet. Show all lifts to see what has been logged.")
            }
            ForEach(visibleLifts) { lift in liftRow(lift) }
            DisclosureLine(title: showAllLifts ? "JUDGED LIFTS ONLY" : "ALL \(snap?.lifts.count ?? 0) LIFTS") {
                Haptic.selection()
                withAnimation(Motion.smooth) { showAllLifts.toggle() }
            }
        }
    }

    private func liftRow(_ lift: LiftReport) -> some View {
        let endOrd = calendar.current.ordinal
        let ords = Array((endOrd - 11)...endOrd)
        let positions = ords.map { BlockPosition.from(ordinal: $0) }
        let values: [Double?] = positions.map { lift.weekly[$0]?.e1rm }
        let mean = ChartMath.mean(values.compactMap { $0 })
        let shaded = Set(positions.enumerated().filter { $0.element.isDeload }.map(\.offset))
        let dividers = Set(positions.enumerated().filter { $0.offset > 0 && $0.element.week == 1 }.map(\.offset))
        var pr = Set<Int>()
        if lift.state == .pr, let p = lift.peak, let i = positions.firstIndex(of: p.position) { pr.insert(i) }
        let color: Color = lift.state == .pr ? Editorial.lime : (lift.state == .up ? Editorial.emerald : (lift.state == .stall || lift.state == .drop ? Editorial.amber : Editorial.mid))
        let caption: String = lift.deltaPct.map { Editorial.signedPct($0) + " vs last block" } ?? "no prior block"
        return PosterRow(
            eyebrow: lift.state == .stall ? "STALLED · \(lift.blocksSincePR ?? 2) BLOCKS" : lift.state.label,
            eyebrowColor: lift.state.inkColor, title: lift.name,
            subtitle: [lift.sessionType, lift.bestSetLine].compactMap { $0 }.joined(separator: " · "),
            value: lift.peak.map { String(Int($0.e1rm.rounded())) } ?? "—", unit: lift.peak == nil ? "" : "KG",
            trailingCaption: caption, trailingCaptionColor: (lift.deltaPct ?? 0) >= 0 ? color : Editorial.amber,
            valueColor: lift.peak == nil ? Editorial.muted : .white,
            titleSize: lift.name.count > 14 ? 28 : 34
        ) {
            RibbonChart(values: values, color: color, shadedSlots: shaded, dividerSlots: dividers, prSlots: pr,
                        range: mean > 0 ? (mean * 0.92)...(mean * 1.08) : nil)
                .frame(height: 110)
                .padding(.top, 6)
            HStack {
                ForEach(Array(positions.enumerated()).filter { $0.element.week == 1 || $0.offset == 0 }, id: \.offset) { _, p in
                    Text(p.shortBlockLabel).font(.system(size: 9, weight: .bold)).kerning(1.5).foregroundStyle(Editorial.muted)
                    Spacer()
                }
            }
            .padding(.horizontal, Editorial.gutter).padding(.bottom, 10)
        }
    }

    // MARK: Balance

    private var balance: some View {
        VStack(spacing: 0) {
            SectionBar(title: "BALANCE", right: "EST. 1RM RATIOS · BAND = REFERENCE")
            ForEach(vm.balance) { b in
                let grey = b.ratioPct == nil
                let inBand = b.ratioPct.map { b.band.contains(Int($0.rounded())) } ?? false
                let col: Color = grey ? Editorial.muted : (inBand ? Editorial.emerald : Editorial.amber)
                PosterRow(eyebrow: "\(b.verdict) · BAND \(b.band.lowerBound)–\(b.band.upperBound)%", eyebrowColor: col, title: b.title,
                          value: b.ratioPct.map { String(Int($0.rounded())) } ?? "—", unit: grey ? "" : "%",
                          valueColor: grey ? Editorial.muted : .white, titleSize: 30) {
                    BalanceBeam(ratioPct: b.ratioPct, band: b.band, color: col)
                        .padding(.horizontal, Editorial.gutter).padding(.top, 18)
                    HStack {
                        Text(b.leftName + (b.leftValue.map { " \(Int($0.rounded()))" } ?? "")).lineLimit(1)
                        Spacer()
                        Text(b.rightName + (b.rightValue.map { " \(Int($0.rounded()))" } ?? "")).lineLimit(1)
                    }
                    .font(.system(size: 10, weight: .semibold)).kerning(1).foregroundStyle(Editorial.muted)
                    .padding(.horizontal, Editorial.gutter).padding(.top, 10).padding(.bottom, 18)
                }
            }
        }
    }
}
