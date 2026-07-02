// PrescriptionCard.swift
// Vaux

import SwiftUI

struct PrescriptionCard: View {
    let prescription: ExercisePrescription
    var exerciseSetIndex: Int = 0
    var loggedSets: [WorkoutSet] = []
    var currentPhase: SetPhase = .working
    var phaseSetIndex: Int = 0

    /// Drives the soft glow pulse on the chip for the set that's up next.
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            exerciseHeader

            if !prescription.warmupSets.isEmpty {
                setSection(
                    label: "WARM-UP",
                    color: .fg1,
                    icon: "flame",
                    sets: prescription.warmupSets.enumerated().map { i, s in
                        SetTarget(weight: s.weight, reps: s.reps, rpe: nil, kind: .warmup, index: i)
                    }
                )
            }

            if !prescription.workingSets.isEmpty {
                setSection(
                    label: "WORKING",
                    color: .mint,
                    icon: "bolt.fill",
                    sets: prescription.workingSets.enumerated().map { i, s in
                        SetTarget(weight: s.weight, reps: s.reps, rpe: s.rpe, kind: .working, index: i)
                    }
                )
            }

            if !prescription.backoffSets.isEmpty {
                setSection(
                    label: "BACK-OFF",
                    color: .amber,
                    icon: "arrow.down.right",
                    sets: prescription.backoffSets.enumerated().map { i, s in
                        SetTarget(weight: s.weight, reps: s.reps, rpe: s.rpe, kind: .backoff, index: i)
                    }
                )
            }

            if prescription.tempo != nil || prescription.formCue != nil {
                cuesSection
            }

            if let rest = prescription.restSeconds {
                restPill(rest)
            }

            // Current target indicator — hidden once all prescribed sets are done
            if !isExerciseFullyLogged {
                currentTargetLabel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.ink2.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.signal.opacity(0.25), Color.line],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: - Exercise header

    private var exerciseHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.signal.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.signal)
            }

            VStack(alignment: .leading, spacing: 3) {
                if exerciseSetIndex > 0 {
                    Text("SET \(exerciseSetIndex) COMPLETE")
                        .font(.eyebrowSmall)
                        .kerning(1.0)
                        .foregroundStyle(Color.mint)
                } else {
                    Eyebrow(text: "Current exercise")
                }
                Text(prescription.exerciseName)
                    .font(.serifMD)
                    .foregroundStyle(Color.fg0)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 0)

            if let w = prescription.targetWeightKg, let r = prescription.targetReps {
                targetBadge(weight: w, reps: r, rpe: prescription.targetRpe)
            }
        }
    }

    private func targetBadge(weight: Double, reps: Int, rpe: Double?) -> some View {
        VStack(spacing: 2) {
            Text("\(formatWeight(weight)) × \(reps)")
                .font(.numSM)
                .foregroundStyle(Color.fg0)
            if let rpe {
                Text("RPE \(formatRPE(rpe))")
                    .font(.eyebrowSmall)
                    .foregroundStyle(Color.mint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.mint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.mint.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Set sections

    private struct SetTarget {
        let weight: Double
        let reps: Int
        let rpe: Double?
        let kind: Kind
        let index: Int
        enum Kind { case warmup, working, backoff }
    }

    private func setSection(label: String, color: Color, icon: String, sets: [SetTarget]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                Text(label)
                    .font(.eyebrow)
                    .kerning(1.2)
                    .foregroundStyle(color)
            }

            ChipFlow(spacing: 6) {
                ForEach(Array(sets.enumerated()), id: \.offset) { _, target in
                    setChip(target: target, color: color)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.06))
        )
    }

    private func setChip(target: SetTarget, color: Color) -> some View {
        let isCompleted = isSetCompleted(target)
        let isCurrent = isCurrentTarget(target)
        let logged = isCompleted ? loggedSetFor(target) : nil
        // For completed chips, show what the athlete actually logged
        // rather than the prescribed target — otherwise a warm-up logged
        // at 90 × 6 against a prescribed 60 × 10 still reads "60 × 10"
        // with a checkmark, which looks like the wrong set got recorded.
        let displayWeight = logged?.actualWeightKg ?? target.weight
        let displayReps = logged?.actualReps ?? target.reps
        let displayRpe = logged?.actualRpe ?? target.rpe
        return VStack(spacing: 3) {
            Text("\(formatWeight(displayWeight)) × \(displayReps)")
                .font(.system(size: 13, weight: .medium, design: .monospaced).monospacedDigit())
                .foregroundStyle(isCompleted ? color : isCurrent ? Color.fg0 : Color.fg1)
            if let rpe = displayRpe {
                Text("@\(formatRPE(rpe))")
                    .font(.eyebrowSmall)
                    .foregroundStyle(isCompleted ? color.opacity(0.7) : Color.fg2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCompleted ? color.opacity(0.12) : isCurrent ? color.opacity(0.18) : Color.ink3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isCompleted ? color.opacity(0.3) : isCurrent ? color.opacity(0.6) : Color.clear,
                    lineWidth: isCurrent ? 1.5 : 0.5
                )
        )
        .shadow(
            color: isCurrent ? color.opacity(pulse ? 0.45 : 0.10) : .clear,
            radius: isCurrent ? (pulse ? 9 : 3) : 0
        )
        .overlay(alignment: .topTrailing) {
            if isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(color)
                    .offset(x: 3, y: -3)
            }
        }
    }

    /// Looks up the persisted set that corresponds to a target chip so the
    /// chip can render the athlete's actual numbers once it's checked off.
    /// Warm-ups index into the warmup queue; working / back-off share the
    /// non-warmup queue with the first N entries being working sets.
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
        // Use the stored is_warmup flag on each logged set so the card stays
        // in sync with the phase the user actually logged, not the order the
        // chips are laid out. Warm-up chips check against warm-up logs;
        // working and back-off chips share the non-warmup queue, with the
        // first N entries being working sets and the rest back-offs.
        let warmupsDone = loggedSets.filter { $0.isWarmup == true }.count
        let nonWarmupsDone = loggedSets.count - warmupsDone
        let workingPrescribed = prescription.workingSets.count

        switch target.kind {
        case .warmup:
            return warmupsDone > target.index
        case .working:
            return nonWarmupsDone > target.index
        case .backoff:
            return nonWarmupsDone > workingPrescribed + target.index
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
        let phaseLabel: String
        let phaseColor: Color
        switch currentPhase {
        case .warmup:
            phaseLabel = "NEXT: WARM-UP \(phaseSetIndex + 1) OF \(prescription.warmupSets.count)"
            phaseColor = .fg1
        case .working:
            phaseLabel = "NEXT: WORKING SET \(phaseSetIndex + 1) OF \(prescription.workingSets.count)"
            phaseColor = .mint
        case .backoff:
            phaseLabel = "NEXT: BACK-OFF \(phaseSetIndex + 1)"
            phaseColor = .amber
        }

        return HStack(spacing: 6) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(phaseColor)
            Text(phaseLabel)
                .font(.eyebrowSmall)
                .kerning(0.8)
                .foregroundStyle(phaseColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(phaseColor.opacity(0.08))
        )
        .overlay(
            Capsule().stroke(phaseColor.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Tempo + form cue

    private var cuesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tempo = prescription.tempo, !tempo.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "metronome.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mint)
                    Text("Tempo: \(tempo)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.fg0)

                    if let desc = tempoDescription(tempo) {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.fg1)
                    }
                }
            }

            if let cue = prescription.formCue, !cue.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.amber)
                    Text(cue)
                        .font(.system(size: 13).italic())
                        .foregroundStyle(Color.fg0.opacity(0.85))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ink1)
        )
    }

    private func tempoDescription(_ tempo: String) -> String? {
        let parts = tempo.components(separatedBy: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return nil }
        return "\(parts[0])s down · \(parts[1])s pause · \(parts[2])s up"
    }

    private func restPill(_ seconds: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "timer")
                .font(.system(size: 10, weight: .semibold))
            Text("REST \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                .font(.eyebrowSmall)
                .kerning(1.0)
        }
        .foregroundStyle(Color.fg1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.ink3))
    }

    // MARK: - Formatting

    private func formatWeight(_ w: Double) -> String {
        // Bodyweight prescriptions parse to weight 0 (Pull-ups, dips, etc.) —
        // render "BW" so the card doesn't claim the athlete is lifting 0kg.
        if w <= 0 { return "BW" }
        return w.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(w))kg" : String(format: "%.1fkg", w)
    }

    private func formatRPE(_ r: Double) -> String {
        r.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(r))" : String(format: "%.1f", r)
    }
}

/// Lays out set chips left-to-right and wraps onto additional rows when a
/// section prescribes more sets than fit the card width — straight-set ab
/// work runs 3-4 working sets, which overflows a fixed HStack on smaller
/// screens.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    private struct Row {
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var index = 0
        var y = bounds.minY
        for row in computeRows(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for size in row.sizes {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += row.height + spacing
        }
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let widthIfAdded = current.sizes.isEmpty
                ? size.width
                : current.width + spacing + size.width
            if !current.sizes.isEmpty, widthIfAdded > maxWidth {
                rows.append(current)
                current = Row()
                current.width = size.width
            } else {
                current.width = widthIfAdded
            }
            current.sizes.append(size)
            current.height = max(current.height, size.height)
        }
        if !current.sizes.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
