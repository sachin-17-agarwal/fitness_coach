// PrescriptionCard.swift
// Vaux

import SwiftUI

struct PrescriptionCard: View {
    let prescription: ExercisePrescription
    var exerciseSetIndex: Int = 0
    var loggedSets: [WorkoutSet] = []
    var currentPhase: SetPhase = .working
    var phaseSetIndex: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            exerciseHeader

            if !prescription.warmupSets.isEmpty {
                setSection(
                    label: "WARM-UP",
                    color: .textSecondary,
                    icon: "flame",
                    sets: prescription.warmupSets.enumerated().map { i, s in
                        SetTarget(weight: s.weight, reps: s.reps, rpe: nil, kind: .warmup, index: i)
                    }
                )
            }

            if !prescription.workingSets.isEmpty {
                setSection(
                    label: "WORKING",
                    color: .recoveryGreen,
                    icon: "bolt.fill",
                    sets: prescription.workingSets.enumerated().map { i, s in
                        SetTarget(weight: s.weight, reps: s.reps, rpe: s.rpe, kind: .working, index: i)
                    }
                )
            }

            if !prescription.backoffSets.isEmpty {
                setSection(
                    label: "BACK-OFF",
                    color: .recoveryYellow,
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

            // Current target indicator
            currentTargetLabel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.recoveryGreen.opacity(0.4), Color.accentTeal.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Exercise header

    private var exerciseHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Gradients.recovery)
                    .frame(width: 42, height: 42)
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                if exerciseSetIndex > 0 {
                    Text("SET \(exerciseSetIndex) COMPLETE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .kerning(0.8)
                        .foregroundStyle(Color.recoveryGreen)
                } else {
                    Text("CURRENT EXERCISE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .kerning(0.8)
                        .foregroundStyle(Color.textTertiary)
                }
                Text(prescription.exerciseName)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
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
                .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
            if let rpe {
                Text("RPE \(formatRPE(rpe))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.recoveryGreen)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.recoveryGreen.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.recoveryGreen.opacity(0.3), lineWidth: 0.5)
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
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .kerning(0.8)
                    .foregroundStyle(color)
            }

            HStack(spacing: 6) {
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
        return VStack(spacing: 3) {
            Text("\(formatWeight(target.weight)) × \(target.reps)")
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(isCompleted ? color : isCurrent ? .white : Color.white.opacity(0.7))
            if let rpe = target.rpe {
                Text("@\(formatRPE(rpe))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(isCompleted ? color.opacity(0.7) : Color.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCompleted ? color.opacity(0.12) : isCurrent ? color.opacity(0.18) : Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isCompleted ? color.opacity(0.3) : isCurrent ? color.opacity(0.6) : Color.clear,
                    lineWidth: isCurrent ? 1.5 : 0.5
                )
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

    // MARK: - Current target label

    private var currentTargetLabel: some View {
        let phaseLabel: String
        let phaseColor: Color
        switch currentPhase {
        case .warmup:
            phaseLabel = "NEXT: WARM-UP \(phaseSetIndex + 1) OF \(prescription.warmupSets.count)"
            phaseColor = .textSecondary
        case .working:
            phaseLabel = "NEXT: WORKING SET \(phaseSetIndex + 1)"
            phaseColor = .recoveryGreen
        case .backoff:
            phaseLabel = "NEXT: BACK-OFF \(phaseSetIndex + 1)"
            phaseColor = .recoveryYellow
        }

        return HStack(spacing: 6) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(phaseColor)
            Text(phaseLabel)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .kerning(0.5)
                .foregroundStyle(phaseColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(phaseColor.opacity(0.1))
        )
    }

    // MARK: - Tempo + form cue

    private var cuesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tempo = prescription.tempo, !tempo.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "metronome.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentTeal)
                    Text("Tempo: \(tempo)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    if let desc = tempoDescription(tempo) {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }

            if let cue = prescription.formCue, !cue.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentAmber)
                    Text(cue)
                        .font(.system(size: 13).italic())
                        .foregroundStyle(Color.white.opacity(0.8))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.surface)
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
            Text("Rest \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.surface))
    }

    // MARK: - Formatting

    private func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(w))kg" : String(format: "%.1fkg", w)
    }

    private func formatRPE(_ r: Double) -> String {
        r.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(r))" : String(format: "%.1f", r)
    }
}
