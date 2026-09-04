// TrainingTabView.swift
// Vaux
//
// The block is the unit: tonnage lifted this block, the wave as it landed
// (with last block ghosted behind), then every session ready to unfold to
// its sets.

import SwiftUI

struct TrainingTabView: View {
    let vm: TrainingBlockViewModel
    let strength: StrengthViewModel
    let recovery: RecoveryInsightsViewModel
    @Binding var tab: HistoryView.Tab
    let askCoach: (String) -> Void

    @State private var expanded: Set<String> = []
    @State private var showReport = false
    /// Blocks whose sessions are listed. The current block opens by default;
    /// older blocks fold to one line each until tapped.
    @State private var openBlocks: Set<Int>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            DiagnosisText(text: TrainingBlockViewModel.diagnosis(vm), coachPrompt: coachPrompt, askCoach: askCoach)
            SectionBar(title: "SESSIONS", right: "BY BLOCK · TAP A BLOCK TO FOLD")
            if vm.entries.isEmpty {
                NoReadNote(text: "No sessions in the last \(TrainingBlockViewModel.windowDays) days. Start one in the Train tab.")
            }
            ForEach(blockGroups, id: \.block) { group in
                blockHeader(group)
                if isOpen(group.block) {
                    ForEach(group.entries) { e in sessionRow(e) }
                }
            }
        }
        .sheet(isPresented: $showReport) {
            BlockReportView(training: vm, strength: strength, recovery: recovery)
        }
    }

    private var hero: some View {
        let p = vm.current
        return HeroPanel(height: 600) {
            VStack(alignment: .leading, spacing: 0) {
                HeroTopBar(left: "TRAINING", right: "\(p.blockLabel) · WEEK \(p.week) · \(p.phaseLabel)")
                HistoryTabChips(selected: $tab).padding(.top, 14)
                EditorialEyebrow(text: "LIFTED THIS BLOCK", color: Editorial.lime, size: 10, kerning: 2.5).padding(.top, 18)
                HStack(alignment: .bottom) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        CountUpFigure(value: vm.blockTonnage / 1000, decimals: vm.blockTonnage >= 100_000 ? 0 : 1, size: 132)
                        Text("T").font(.display(56)).foregroundStyle(Editorial.lime)
                    }
                    Spacer()
                    StatStack(lines: [
                        .init(text: "\(vm.blockSessions) SESSIONS"),
                        .init(text: "\(vm.blockSets) SETS"),
                        .init(text: vm.blockDeltaPct.map { Editorial.signedPct($0, decimals: 0) + " VS SAME POINT LAST BLOCK" } ?? "NO PRIOR BLOCK",
                              color: (vm.blockDeltaPct ?? 0) >= 0 && vm.blockDeltaPct != nil ? Editorial.lime : Editorial.mid),
                    ]).padding(.bottom, 10)
                }
                .frame(height: 124)
                HStack {
                    Spacer()
                    Button {
                        Haptic.light(); showReport = true
                    } label: {
                        HStack(spacing: 6) {
                            Text("BLOCK REPORT").font(.system(size: 9.5, weight: .bold)).kerning(2)
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(Editorial.lime)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .overlay(Capsule().stroke(Editorial.lime.opacity(0.4), lineWidth: 1))
                        .frame(minHeight: 34)
                    }
                    .buttonStyle(.plain)
                }
                WaveBarsChart(bars: zip(vm.currentWave, vm.previousWave).map { cur, prev in
                    WaveBarsChart.Bar(label: "W\(cur.position.week)", phase: cur.position.phaseLabel + (cur.position == p ? " · NOW" : ""),
                                      value: cur.tonnage, ghost: prev.tonnage, highlight: cur.position == p)
                })
                .frame(height: 230)
                .padding(.horizontal, -Editorial.gutter)
                .padding(.top, 8)
                EditorialEyebrow(text: "DASHED = LAST BLOCK, SAME WEEK", color: Editorial.muted, size: 9, kerning: 1.5)
                    .padding(.top, 4)
            }
            .padding(.horizontal, Editorial.gutter)
            .padding(.top, 58)
        }
    }

    private var coachPrompt: String? {
        guard vm.blockSessions > 0 else { return nil }
        var lines = ["Looking at my Training tab (\(vm.current.blockLabel.lowercased()), week \(vm.current.week)):",
                     "- \(Editorial.tonnage(vm.blockTonnage)) lifted over \(vm.blockSessions) sessions and \(vm.blockSets) working sets"]
        for w in vm.currentWave where w.tonnage > 0 { lines.append("- week \(w.position.week) (\(w.position.phaseLabel.lowercased())): \(Editorial.tonnage(w.tonnage))") }
        if let d = vm.blockDeltaPct { lines.append("- \(Editorial.signedPct(d, decimals: 0)) against the same point of last block (\(vm.blockSessions) sessions in)") }
        lines.append("Is the wave landing the way it should?")
        return lines.joined(separator: "\n")
    }

    // MARK: Sessions by block

    private struct BlockGroup {
        let block: Int          // Int.min for sessions the calendar could not place
        let entries: [SessionEntry]
        var tonnage: Double { entries.reduce(0) { $0 + $1.tonnage } }
        var range: (start: String, end: String)? {
            let dates = entries.map(\.date).sorted()
            guard let a = dates.first, let b = dates.last else { return nil }
            return (a, b)
        }
    }

    /// Newest block first, each with its sessions newest first.
    private var blockGroups: [BlockGroup] {
        var byBlock: [Int: [SessionEntry]] = [:]
        for e in vm.entries { byBlock[e.position?.block ?? Int.min, default: []].append(e) }
        return byBlock.keys.sorted(by: >).map { BlockGroup(block: $0, entries: byBlock[$0] ?? []) }
    }

    private func isOpen(_ block: Int) -> Bool {
        (openBlocks ?? [vm.current.block]).contains(block)
    }

    private func toggle(_ block: Int) {
        var set = openBlocks ?? [vm.current.block]
        if set.contains(block) { set.remove(block) } else { set.insert(block) }
        openBlocks = set
    }

    /// One ruled line per block: its label and dates on the left, sessions
    /// and tonnage on the right, a chevron for the fold.
    private func blockHeader(_ group: BlockGroup) -> some View {
        let open = isOpen(group.block)
        let isCurrent = group.block == vm.current.block
        let label: String = group.block == Int.min ? "UNPLACED" : BlockPosition(block: group.block, week: 1).blockLabel
        let dates = group.range.map(BlockCalendar.shortRange) ?? ""
        let n = group.entries.count
        return Button {
            Haptic.selection()
            withAnimation(Motion.smooth) { toggle(group.block) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                EditorialEyebrow(text: label, color: isCurrent ? Editorial.lime : Editorial.mid, size: 10, kerning: 2.5)
                if !dates.isEmpty {
                    EditorialEyebrow(text: dates, color: Editorial.muted, size: 9.5, kerning: 1.5)
                }
                Spacer()
                EditorialEyebrow(text: "\(n) SESSION\(n == 1 ? "" : "S") · \(Editorial.tonnage(group.tonnage))", color: Editorial.muted, size: 9.5, kerning: 1.5)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Editorial.muted)
                    .rotationEffect(.degrees(open ? 0 : -90))
            }
            .padding(.horizontal, Editorial.gutter)
            .frame(height: 44)
            .background(Editorial.wash.opacity(isCurrent ? 0 : 1))
            .overlay(alignment: .top) { Rectangle().fill(Editorial.rule).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(n) sessions")
        .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
    }

    private func sessionRow(_ e: SessionEntry) -> some View {
        let open = expanded.contains(e.id)
        let dateText: String = {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            guard let d = f.date(from: e.date) else { return e.date }
            return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
        }()
        let posText = e.position.map { " · \($0.shortBlockLabel) W\($0.week)" } ?? ""
        let meta = [e.setCount > 0 ? "\(e.setCount) sets" : nil, e.durationLine].compactMap { $0 }.joined(separator: " · ")
        return Button {
            Haptic.selection()
            withAnimation(Motion.smooth) { if open { expanded.remove(e.id) } else { expanded.insert(e.id) } }
        } label: {
            PosterRow(eyebrow: dateText + posText, eyebrowColor: Editorial.muted,
                      title: e.type.replacingOccurrences(of: "+", with: " + "),
                      subtitle: meta, value: Editorial.tonnage(e.tonnage), titleSize: 34) {
                if e.isOpen {
                    EditorialEyebrow(text: "● IN PROGRESS", color: Editorial.amber, size: 10, kerning: 2)
                        .padding(.horizontal, Editorial.gutter).padding(.top, 8)
                }
                if open {
                    VStack(spacing: 0) {
                        ForEach(e.exercises.indices, id: \.self) { i in
                            let (name, sets) = e.exercises[i]
                            HStack(alignment: .firstTextBaseline) {
                                Text(name).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                                Spacer(minLength: 8)
                                Text(setLine(sets)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Editorial.mid)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                            .padding(.vertical, 8)
                            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
                        }
                        if e.exercises.isEmpty {
                            Text(e.sets.isEmpty ? "No sets logged." : "Cardio or mobility only.")
                                .font(.system(size: 12)).foregroundStyle(Editorial.muted).padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, Editorial.gutter).padding(.top, 14).padding(.bottom, 18)
                } else {
                    Text(e.summaryLine)
                        .font(.system(size: 11)).kerning(0.5).foregroundStyle(Editorial.muted).lineLimit(1)
                        .padding(.horizontal, Editorial.gutter).padding(.top, 10).padding(.bottom, 20)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(open ? "Collapses the sets" : "Shows every set")
    }

    private func setLine(_ sets: [WorkoutSet]) -> String {
        let weights = Set(sets.compactMap { $0.actualWeightKg }.filter { $0 > 0 })
        let reps = sets.compactMap { $0.actualReps }.map(String.init).joined(separator: " · ")
        if weights.isEmpty { return reps.isEmpty ? "\(sets.count) sets" : reps }
        if weights.count == 1, let w = weights.first { return "\(SessionEntry.kg(w)) × \(reps)" }
        return sets.compactMap { s in s.actualWeightKg.map { "\(SessionEntry.kg($0))×\(s.actualReps ?? 0)" } }.joined(separator: " · ")
    }
}
