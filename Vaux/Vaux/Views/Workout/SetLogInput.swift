// SetLogInput.swift
// Vaux

import SwiftUI

struct SetLogInput: View {
    @Binding var weight: Double
    @Binding var reps: Int
    @Binding var rpe: Double
    let onLog: () -> Void
    let isLoading: Bool
    var phase: SetPhase = .working

    private var isWarmup: Bool { phase == .warmup }

    private var phaseColor: Color {
        switch phase {
        case .warmup: return .textSecondary
        case .working: return .recoveryGreen
        case .backoff: return .recoveryYellow
        }
    }

    private var buttonLabel: String {
        switch phase {
        case .warmup: return "Log warm-up"
        case .working: return "Log set"
        case .backoff: return "Log back-off"
        }
    }

    private var buttonGradient: AnyShapeStyle {
        switch phase {
        case .warmup: return AnyShapeStyle(Color.surfaceRaised)
        case .working: return AnyShapeStyle(Gradients.recovery)
        case .backoff: return AnyShapeStyle(Gradients.cool)
        }
    }

    private var buttonTextColor: Color {
        phase == .warmup ? .white : .black
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(phaseColor).frame(width: 6, height: 6)
                    Text(phase.rawValue.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .kerning(1)
                        .foregroundStyle(phaseColor)
                }
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

            if !isWarmup {
                RPESlider(value: $rpe)
            }

            Button(action: {
                Haptic.medium()
                onLog()
            }) {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView().tint(buttonTextColor)
                    } else {
                        Image(systemName: isWarmup ? "flame" : "checkmark")
                            .font(.system(size: 13, weight: .bold))
                        Text(buttonLabel)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                }
                .foregroundStyle(buttonTextColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(buttonGradient)
                )
                .overlay {
                    if isWarmup {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.cardBorder, lineWidth: 0.5)
                    }
                }
                .shadow(color: isWarmup ? .clear : phaseColor.opacity(0.3), radius: 14, x: 0, y: 8)
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
