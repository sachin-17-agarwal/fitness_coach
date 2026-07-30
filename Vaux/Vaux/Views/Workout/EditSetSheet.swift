// EditSetSheet.swift
// Vaux
//
// Correct or remove a set that was logged wrong.
//
// Until this existed the only way to fix a mis-entered set was to tell the
// coach in prose ("actually last set was 205x10") — which left the database
// holding the wrong numbers while the conversation held the right ones, so
// every downstream reader (progression, tonnage, the strength charts) kept
// using the bad row.

import SwiftUI

struct EditSetSheet: View {
    let set: WorkoutSet
    let onSave: (Double, Int, Double?) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var weight: Double
    @State private var reps: Int
    @State private var rpe: Double
    @State private var confirmingDelete = false

    private var isWarmup: Bool { set.isWarmup == true }

    init(
        set: WorkoutSet,
        onSave: @escaping (Double, Int, Double?) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.set = set
        self.onSave = onSave
        self.onDelete = onDelete
        _weight = State(initialValue: set.actualWeightKg ?? 0)
        _reps = State(initialValue: set.actualReps ?? 0)
        _rpe = State(initialValue: set.actualRpe ?? 8)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.ink0.ignoresSafeArea()

                VStack(spacing: 24) {
                    header

                    stepperRow(
                        label: "WEIGHT",
                        value: weight <= 0 ? "BW" : "\(weight.wholeOrOne)kg",
                        onMinus: { weight = max(0, weight - 2.5) },
                        onPlus: { weight += 2.5 }
                    )

                    stepperRow(
                        label: "REPS",
                        value: "\(reps)",
                        onMinus: { reps = max(0, reps - 1) },
                        onPlus: { reps += 1 }
                    )

                    if !isWarmup {
                        stepperRow(
                            label: "RPE",
                            value: rpe.oneDecimal,
                            onMinus: { rpe = max(1, rpe - 0.5) },
                            onPlus: { rpe = min(10, rpe + 0.5) }
                        )
                    }

                    Spacer()

                    deleteButton
                }
                .padding(20)
            }
            .navigationTitle("Edit set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.fg2)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Haptic.medium()
                        onSave(weight, reps, isWarmup ? nil : rpe)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.signal)
                    .disabled(reps <= 0)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(set.exercise)
                .font(.serifSM)
                .foregroundStyle(Color.fg0)
            Text(isWarmup ? "WARM-UP · SET \(set.setNumber)" : "SET \(set.setNumber)")
                .font(.eyebrowSmall)
                .kerning(1.6)
                .foregroundStyle(Color.fg2)
        }
        .padding(.top, 8)
    }

    private func stepperRow(
        label: String,
        value: String,
        onMinus: @escaping () -> Void,
        onPlus: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(label)
                .font(.eyebrowSmall)
                .kerning(1.4)
                .foregroundStyle(Color.fg2)
                .frame(width: 70, alignment: .leading)

            Spacer()

            stepButton("minus") { Haptic.light(); onMinus() }

            Text(value)
                .font(.numMD)
                .foregroundStyle(Color.fg0)
                .frame(minWidth: 92)
                .multilineTextAlignment(.center)

            stepButton("plus") { Haptic.light(); onPlus() }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.ink2)
        )
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.fg0)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.ink3))
        }
        .buttonStyle(PressScaleStyle())
    }

    /// Two-step on purpose — a mis-tap here destroys a set the athlete
    /// actually performed, which is worse than the mistake being fixed.
    private var deleteButton: some View {
        Button {
            if confirmingDelete {
                Haptic.warning()
                onDelete()
                dismiss()
            } else {
                Haptic.light()
                withAnimation(Motion.smooth) { confirmingDelete = true }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                Text(confirmingDelete ? "Tap again to delete" : "Delete this set")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.ember)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.ember.opacity(confirmingDelete ? 0.18 : 0.08))
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}
