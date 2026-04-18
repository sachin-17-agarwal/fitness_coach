// PrescriptionCard.swift
// Vaux
//
// Displays a parsed AI exercise prescription — exercise name, warm-up,
// working/back-off set targets, form cue, and rest duration.

import SwiftUI

struct PrescriptionCard: View {
    let prescription: ExercisePrescription

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !prescription.warmupSets.isEmpty {
                setBlock(
                    label: "Warm-up",
                    color: .textSecondary,
                    sets: prescription.warmupSets.map { setLine(weight: $0.weight, reps: $0.reps, rpe: nil) }
                )
            }

            if !prescription.workingSets.isEmpty {
                setBlock(
                    label: "Working",
                    color: .recoveryGreen,
                    sets: prescription.workingSets.map { setLine(weight: $0.weight, reps: $0.reps, rpe: $0.rpe) }
                )
            }

            if !prescription.backoffSets.isEmpty {
                setBlock(
                    label: "Back-off",
                    color: .recoveryYellow,
                    sets: prescription.backoffSets.map { setLine(weight: $0.weight, reps: $0.reps, rpe: $0.rpe) }
                )
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
                .padding(.top, 2)
            }

            if let rest = prescription.restSeconds {
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Rest \(rest / 60):\(String(format: "%02d", rest % 60))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.surface))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 16, cornerRadius: 18)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Gradients.recovery)
                    .frame(width: 36, height: 36)
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT UP")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .kerning(0.8)
                    .foregroundStyle(Color.textTertiary)
                Text(prescription.exerciseName)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Spacer()
        }
    }

    private func setBlock(label: String, color: Color, sets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .kerning(0.8)
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(sets.enumerated()), id: \.offset) { _, s in
                    Text(s)
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.surface)
        )
    }

    private func setLine(weight: Double, reps: Int, rpe: Double?) -> String {
        var s = "\(formatWeight(weight)) × \(reps)"
        if let rpe { s += "  @RPE \(formatRPE(rpe))" }
        return s
    }

    private func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(w)) kg" : String(format: "%.1f kg", w)
    }

    private func formatRPE(_ r: Double) -> String {
        r.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(r))" : String(format: "%.1f", r)
    }
}
