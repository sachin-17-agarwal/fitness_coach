// PrescriptionCard.swift
// Vaux

import SwiftUI

struct PrescriptionCard: View {
    let prescription: ExercisePrescription
    var exerciseSetIndex: Int = 0
    var loggedSets: [WorkoutSet] = []

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

            if let cue = prescription.formCue, !cue.isEmpty {
                formCueRow(cue)
            }

            if let rest = prescription.restSeconds {
                restPill(rest)
            }
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
        return VStack(spacing: 3) {
            Text("\(formatWeight(target.weight)) × \(target.reps)")
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(isCompleted ? color : .white)
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
                .fill(isCompleted ? color.opacity(0.12) : Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isCompleted ? color.opacity(0.3) : Color.clear, lineWidth: 0.5)
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

    private func isSetCompleted(_ target: SetTarget) -> Bool {
        let matchingSets = loggedSets.filter { set in
            let w = set.actualWeightKg ?? 0
            return abs(w - target.weight) < 1.0
        }

        switch target.kind {
        case .warmup:
            return matchingSets.count > target.index
        case .working:
            let warmupCount = prescription.warmupSets.count
            return loggedSets.count > warmupCount + target.index
        case .backoff:
            let priorCount = prescription.warmupSets.count + prescription.workingSets.count
            return loggedSets.count > priorCount + target.index
        }
    }

    // MARK: - Form cue + rest

    private func formCueRow(_ cue: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentAmber)
            Text(cue)
                .font(.system(size: 13).italic())
                .foregroundStyle(Color.white.opacity(0.8))
        }
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
