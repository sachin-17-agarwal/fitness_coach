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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            DiagnosisText(text: TrainingBlockViewModel.diagnosis(vm), coachPrompt: coachPrompt, askCoach: askCoach)
            SectionBar(title: "SESSIONS", right: "\(vm.blockSessions) THIS BLOCK · TAP TO OPEN")
            if vm.entries.isEmpty {
                NoReadNote(text: "No sessions in the last \(TrainingBlockViewModel.windowDays) days. Start one in the Train tab.")
            }
            ForEach(vm.entries) { e in sessionRow(e) }
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
                        .init(text: vm.blockDeltaPct.map { Editorial.signedPct($0, decimals: 0) + " VS LAST BLOCK" } ?? "NO PRIOR BLOCK",
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
        if let d = vm.blockDeltaPct { lines.append("- \(Editorial.signedPct(d, decimals: 0)) against the same weeks of last block") }
        lines.append("Is the wave landing the way it should?")
        return lines.joined(separator: "\n")
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
