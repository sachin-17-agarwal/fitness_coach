// PrescriptionCard.swift
// Vaux
//
// The current exercise as the coach prescribed it: position and rest in the
// eyebrow, the name in the display face, the sets grouped by phase as chips
// (the working chip is the target; last block's same-week set sits beside
// it), tempo as digits with direction, and the cue. Same completion logic
// as before — done chips show what was actually logged and open the editor.

import SwiftUI

/// The same working set from the same week of the previous block, so the
/// comparison never crosses a phase (a volume week is never judged against a
/// peak week). nil when the lift has no history a block back.
struct LastBlockReference: Equatable {
    let weight: Double
    let reps: Int
    let rpe: Double?
    /// "Wk 1" — the week both sets belong to.
    let weekLabel: String
}

struct PrescriptionCard: View {
    let prescription: ExercisePrescription
    let exerciseSetIndex: Int
    let loggedSets: [WorkoutSet]
    let currentPhase: SetPhase
    let phaseSetIndex: Int
    /// 1-based position of this exercise in the session, and the session's
    /// exercise count. Either nil hides the position eyebrow.
    var exerciseIndex: Int? = nil
    var exerciseCount: Int? = nil
    var lastBlock: LastBlockReference? = nil
    let onEditSet: (WorkoutSet) -> Void

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            exerciseHeader

            VStack(alignment: .leading, spacing: 0) {
                if !prescription.warmupSets.isEmpty {
                    setSection(
                        label: "Warm-up", color: .fg2, first: true,
                        sets: prescription.warmupSets.enumerated().map { i, s in
                            SetTarget(weight: s.weight, reps: s.reps, repsHigh: nil, rpe: nil, kind: .warmup, index: i)
                        },
                        trailing: nil
                    )
                }
                if !prescription.workingSets.isEmpty {
                    setSection(
                        label: "Working", color: .mint, first: prescription.warmupSets.isEmpty,
                        sets: prescription.workingSets.enumerated().map { i, s in
                            SetTarget(weight: s.weight, reps: s.reps, repsHigh: s.repsHigh, rpe: s.rpe, kind: .working, index: i)
                        },
                        trailing: lastBlock
                    )
                }
                if !prescription.backoffSets.isEmpty {
                    setSection(
                        label: "Back-off", color: .amber,
                        first: prescription.warmupSets.isEmpty && prescription.workingSets.isEmpty,
                        sets: prescription.backoffSets.enumerated().map { i, s in
                            SetTarget(weight: s.weight, reps: s.reps, repsHigh: s.repsHigh, rpe: s.rpe, kind: .backoff, index: i)
                        },
                        trailing: nil
                    )
                }
            }
            .padding(.top, 8)

            if prescription.tempo != nil || prescription.formCue != nil || prescription.why != nil {
                cuesSection
            }

            if !isExerciseFullyLogged {
                HStack {
                    Spacer()
                    currentTargetLabel
                }
                .padding(.top, 12)
                .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ink2.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.line, lineWidth: 1))
        .onAppear {
            guard !reduceMotion else {
                pulse = true
                return
            }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: - Exercise header

    private var exerciseHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let exerciseIndex, let exerciseCount {
                    EditorialEyebrow(text: "Exercise \(exerciseIndex) of \(exerciseCount)", color: Editorial.muted, size: 9.5, kerning: 2)
                } else if exerciseSetIndex > 0 {
                    EditorialEyebrow(text: "Set \(exerciseSetIndex) complete", color: .mint, size: 9.5, kerning: 2)
                } else {
                    EditorialEyebrow(text: "Current exercise", color: Editorial.muted, size: 9.5, kerning: 2)
                }
                Spacer()
                if let rest = prescription.restSeconds {
                    EditorialEyebrow(text: "Rest \(rest / 60):\(String(format: "%02d", rest % 60))", color: Editorial.muted, size: 9.5, kerning: 2)
                }
            }
            Text(prescription.exerciseName.uppercased())
                .font(.display(36))
                .foregroundStyle(Color.fg0)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: - Set sections

    private struct SetTarget {
        let weight: Double
        let reps: Int
        let repsHigh: Int?
        let rpe: Double?
        let kind: Kind
        let index: Int
        enum Kind { case warmup, working, backoff }
    }

    private func setSection(
        label: String, color: Color, first: Bool, sets: [SetTarget], trailing: LastBlockReference?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 6, height: 6)
                EditorialEyebrow(text: label, color: color, size: 10, kerning: 2.2)
            }
            HStack(alignment: .center, spacing: 8) {
                ChipFlow(spacing: 8) {
                    ForEach(Array(sets.enumerated()), id: \.offset) { _, target in
                        setChip(target: target, color: color)
                    }
                }
                if let trailing {
                    lastBlockStack(trailing, against: sets.first)
                }
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Color.line).frame(height: 1) }
        }
    }

    /// The same-week set from the previous block, ruled off beside the
    /// working chip, with the change in load.
    private func lastBlockStack(_ ref: LastBlockReference, against target: SetTarget?) -> some View {
        let delta = target.map { $0.weight - ref.weight } ?? 0
        let load = ExerciseCatalog.setWeightLabel(ref.weight, exercise: prescription.exerciseName)
        return HStack(spacing: 14) {
            Rectangle().fill(Color.line).frame(width: 1, height: 40)
            VStack(alignment: .leading, spacing: 5) {
                EditorialEyebrow(text: "Last block · \(ref.weekLabel)", color: Editorial.muted, size: 8.5, kerning: 1.5)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(load) × \(ref.reps)")
                        .font(.display(18))
                        .foregroundStyle(Color.fg2)
                    if let rpe = ref.rpe {
                        EditorialEyebrow(text: "@\(rpe.wholeOrOne)", color: Editorial.muted, size: 9, kerning: 1)
                    }
                    if delta != 0 {
                        Text("\(delta > 0 ? "▲" : "▼") \(abs(delta).wholeOrOne)")
                            .font(.display(14))
                            .foregroundStyle(delta > 0 ? Color.mint : Color.amber)
                    }
                }
            }
        }
        .padding(.leading, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Last block, \(ref.weekLabel): \(load) by \(ref.reps)")
    }

    private func setChip(target: SetTarget, color: Color) -> some View {
        let isCompleted = isSetCompleted(target)
        let isCurrent = isCurrentTarget(target)
        let logged = isCompleted ? loggedSetFor(target) : nil
        let displayWeight = logged?.actualWeightKg ?? target.weight
        let displayReps = logged?.actualReps ?? target.reps
        let displayRpe = logged?.actualRpe ?? target.rpe
        let repsText: String = {
            if !isCompleted, let high = target.repsHigh, high > target.reps {
                return "\(target.reps)–\(high)"
            }
            return "\(displayReps)"
        }()
        let load = ExerciseCatalog.setWeightLabel(displayWeight, exercise: prescription.exerciseName)
        return VStack(spacing: 3) {
            Text("\(load) × \(repsText)")
                .font(.display(17))
                .foregroundStyle(isCompleted ? color : isCurrent ? Color.fg0 : Color.fg1)
                .lineLimit(1)
            if let rpe = displayRpe {
                EditorialEyebrow(text: "@\(rpe.wholeOrOne)", color: isCompleted ? color.opacity(0.8) : isCurrent ? Color.fg1 : Color.fg3, size: 9, kerning: 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCompleted ? color.opacity(0.14) : isCurrent ? color.opacity(0.16) : Color.ink3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isCompleted ? color.opacity(0.35) : isCurrent ? color : Color.clear, lineWidth: isCurrent ? 1.5 : 1)
        )
        .shadow(color: isCurrent ? color.opacity(pulse ? 0.4 : 0.1) : .clear, radius: isCurrent ? (pulse ? 10 : 3) : 0)
        .overlay(alignment: .topTrailing) {
            if isCompleted {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(Color.signalInk)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(color))
                    .offset(x: 5, y: -5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            guard let logged, logged.id != nil else { return }
            Haptic.light()
            onEditSet(logged)
        }
    }

    private func loggedSetFor(_ target: SetTarget) -> WorkoutSet? {
        let warmups = loggedSets.filter { $0.isWarmup == true }
        let nonWarmups = loggedSets.filter { $0.isWarmup != true }
        switch target.kind {
        case .warmup:
            return target.index < warmups.count ? warmups[target.index] : nil
        case .working:
            return target.index < nonWarmups.count ? nonWarmups[target.index] : nil
        case .backoff:
            let backoffIndex = prescription.workingSets.count + target.index
            return backoffIndex < nonWarmups.count ? nonWarmups[backoffIndex] : nil
        }
    }

    private func isCurrentTarget(_ target: SetTarget) -> Bool {
        guard !isSetCompleted(target) else { return false }
        let targetPhase: SetPhase
        switch target.kind {
        case .warmup: targetPhase = .warmup
        case .working: targetPhase = .working
        case .backoff: targetPhase = .backoff
        }
        return targetPhase == currentPhase && target.index == phaseSetIndex
    }

    private func isSetCompleted(_ target: SetTarget) -> Bool {
        let warmupsDone = loggedSets.filter { $0.isWarmup == true }.count
        let nonWarmupsDone = loggedSets.count - warmupsDone
        let workingPrescribed = prescription.workingSets.count
        switch target.kind {
        case .warmup: return warmupsDone > target.index
        case .working: return nonWarmupsDone > target.index
        case .backoff: return nonWarmupsDone > workingPrescribed + target.index
        }
    }

    private var isExerciseFullyLogged: Bool {
        let warmupsDone = loggedSets.filter { $0.isWarmup == true }.count
        let nonWarmupsDone = loggedSets.count - warmupsDone
        let totalNonWarmup = prescription.workingSets.count + prescription.backoffSets.count
        return warmupsDone >= prescription.warmupSets.count && nonWarmupsDone >= totalNonWarmup
    }

    // MARK: - Current target label

    private var currentTargetLabel: some View {
        let label: String
        let color: Color
        switch currentPhase {
        case .warmup:
            label = "Next · warm-up \(phaseSetIndex + 1) of \(prescription.warmupSets.count)"
            color = .fg2
        case .working:
            label = "Next · working set \(phaseSetIndex + 1) of \(prescription.workingSets.count)"
            color = .mint
        case .backoff:
            label = "Next · back-off \(phaseSetIndex + 1) of \(max(prescription.backoffSets.count, 1))"
            color = .amber
        }
        return EditorialEyebrow(text: label, color: color, size: 10, kerning: 2)
    }

    // MARK: - Tempo + cue

    private var cuesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let tempo = prescription.tempo, !tempo.isEmpty {
                HStack(alignment: .center, spacing: 16) {
                    EditorialEyebrow(text: "Tempo", color: Editorial.muted, size: 9.5, kerning: 2)
                    tempoDigits(tempo)
                    Spacer()
                    if let total = tempoTotal(tempo) {
                        EditorialEyebrow(text: "\(total) s per rep", color: Editorial.muted, size: 9, kerning: 1.4)
                    }
                }
                .frame(height: 48)
            }
            if let cue = prescription.formCue, !cue.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    EditorialEyebrow(text: "Cue", color: Editorial.muted, size: 9.5, kerning: 2)
                        .padding(.top, 2)
                    Text(cue)
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .foregroundStyle(Color.fg1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) {
                    if prescription.tempo != nil { Rectangle().fill(Color.line).frame(height: 1) }
                }
            }
            if let why = prescription.why, !why.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    EditorialEyebrow(text: "Why", color: Editorial.muted, size: 9.5, kerning: 2)
                        .padding(.top, 2)
                    Text(why)
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .foregroundStyle(Color.bone)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) {
                    if prescription.tempo != nil || prescription.formCue != nil {
                        Rectangle().fill(Color.line).frame(height: 1)
                    }
                }
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
    }

    /// "3-1-1" → 3↓ 1■ 1↑: the digits carry their own direction.
    private func tempoDigits(_ tempo: String) -> some View {
        let parts = tempoParts(tempo)
        let marks: [(String, Color)] = [("↓", .mint), ("■", .fg2), ("↑", .signal)]
        return HStack(alignment: .firstTextBaseline, spacing: 18) {
            if parts.count >= 3 {
                ForEach(0..<3, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(parts[i])")
                            .font(.display(22))
                            .foregroundStyle(Color.fg0)
                        Text(marks[i].0)
                            .font(.system(size: i == 1 ? 10 : 12, weight: .bold))
                            .foregroundStyle(marks[i].1)
                    }
                }
            } else {
                Text(tempo)
                    .font(.display(22))
                    .foregroundStyle(Color.fg0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tempoSpoken(tempo))
    }

    private func tempoParts(_ tempo: String) -> [Int] {
        tempo.components(separatedBy: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func tempoTotal(_ tempo: String) -> Int? {
        let parts = tempoParts(tempo)
        return parts.count >= 3 ? parts.reduce(0, +) : nil
    }

    private func tempoSpoken(_ tempo: String) -> String {
        let parts = tempoParts(tempo)
        guard parts.count >= 3 else { return "Tempo \(tempo)" }
        return "Tempo: \(parts[0]) seconds down, \(parts[1]) pause, \(parts[2]) up"
    }
}

// MARK: - Chip flow layout

private struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.indices.append(i)
            current.width = current.indices.count == 1 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
