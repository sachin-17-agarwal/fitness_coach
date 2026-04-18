// SetLogInput.swift
// Vaux
//
// Structured set logging: weight stepper (±2.5 kg), rep stepper, RPE slider.

import SwiftUI

struct SetLogInput: View {
    @Binding var weight: Double
    @Binding var reps: Int
    @Binding var rpe: Double
    let onLog: () -> Void
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("LOG SET")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .kerning(1)
                    .foregroundStyle(Color.textTertiary)
                Spacer()
            }

            HStack(spacing: 10) {
                stepper(
                    label: "Weight",
                    value: weight.weightString,
                    minus: {
                        Haptic.soft()
                        weight = max(0, weight - 2.5)
                    },
                    plus: {
                        Haptic.soft()
                        weight += 2.5
                    }
                )
                stepper(
                    label: "Reps",
                    value: "\(reps)",
                    minus: {
                        Haptic.soft()
                        reps = max(1, reps - 1)
                    },
                    plus: {
                        Haptic.soft()
                        reps += 1
                    }
                )
            }

            RPESlider(value: $rpe)

            Button(action: {
                Haptic.medium()
                onLog()
            }) {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                        Text("Log set")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Gradients.recovery)
                )
                .shadow(color: Color.recoveryGreen.opacity(0.3), radius: 14, x: 0, y: 8)
            }
            .disabled(isLoading)
        }
        .padding(16)
        .darkCard(padding: 0, cornerRadius: 18)
    }

    private func stepper(label: String, value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .kerning(0.8)
                .foregroundStyle(Color.textTertiary)

            HStack(spacing: 8) {
                Button(action: minus) {
                    Image(systemName: "minus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.surface))
                }

                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 70)
                    .contentTransition(.numericText())

                Button(action: plus) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.surface))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.surfaceRaised)
        )
    }
}
