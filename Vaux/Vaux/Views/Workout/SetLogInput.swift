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

    @FocusState private var weightFieldFocused: Bool

    private var isWarmup: Bool { phase == .warmup }

    private var phaseColor: Color {
        switch phase {
        case .warmup: return .fg1
        case .working: return .mint
        case .backoff: return .amber
        }
    }

    private var buttonLabel: String {
        switch phase {
        case .warmup: return "Log warm-up"
        case .working: return "Log set"
        case .backoff: return "Log back-off"
        }
    }

    private var buttonFill: Color {
        switch phase {
        case .warmup: return .ink3
        case .working: return .signal
        case .backoff: return .amber
        }
    }

    private var buttonTextColor: Color {
        phase == .warmup ? .fg0 : .signalInk
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(phaseColor).frame(width: 6, height: 6)
                    Text(phase.rawValue.uppercased())
                        .font(.eyebrow)
                        .kerning(1.4)
                        .foregroundStyle(phaseColor)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                weightStepper(
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
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .foregroundStyle(buttonTextColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(buttonFill)
                )
                .overlay {
                    if isWarmup {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.line2, lineWidth: 1)
                    }
                }
                .shadow(color: isWarmup ? .clear : buttonFill.opacity(0.25), radius: 14, x: 0, y: 8)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(isLoading)
        }
        .padding(16)
        .darkCard(padding: 0, cornerRadius: 18)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { weightFieldFocused = false }
                    .font(.system(size: 16, weight: .semibold))
            }
        }
    }

    /// Weight entry: ±2.5 kg buttons for quick nudges, plus a tappable numeric
    /// field so the athlete can type the exact load any machine, cable stack,
    /// or fixed dumbbell actually provides (e.g. 24 kg, 57.5 kg, 1.25 kg micro
    /// jumps) instead of being locked to 2.5 kg increments.
    ///
    /// The text field renders as plain text on the same surfaceRaised
    /// background as the reps stepper — no inset rectangle. A 1pt
    /// underline shows in `textTertiary` by default (a quiet "this is
    /// editable" cue) and shifts to the phase accent at 2pt on focus.
    private func weightStepper(minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Text("WEIGHT")
                .font(.eyebrowSmall)
                .kerning(1.0)
                .foregroundStyle(Color.fg2)

            HStack(spacing: 8) {
                Button(action: minus) {
                    Image(systemName: "minus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.fg0)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.ink1))
                }

                VStack(spacing: 3) {
                    TextField("0", value: $weight,
                              format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .focused($weightFieldFocused)
                        .font(.system(size: 20, weight: .medium, design: .monospaced).monospacedDigit())
                        .foregroundStyle(Color.fg0)
                        .frame(minWidth: 70)
                        .onChange(of: weight) { _, newValue in
                            if newValue < 0 { weight = 0 }
                        }

                    Rectangle()
                        .fill(weightFieldFocused ? phaseColor : Color.fg2.opacity(0.35))
                        .frame(width: 36, height: weightFieldFocused ? 2 : 1)
                        .animation(.easeOut(duration: 0.15), value: weightFieldFocused)
                }

                Button(action: plus) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.fg0)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.ink1))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.ink3)
        )
    }

    private func stepper(label: String, value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Text(label.uppercased())
                .font(.eyebrowSmall)
                .kerning(1.0)
                .foregroundStyle(Color.fg2)

            HStack(spacing: 8) {
                Button(action: minus) {
                    Image(systemName: "minus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.fg0)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.ink1))
                }

                Text(value)
                    .font(.system(size: 20, weight: .medium, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Color.fg0)
                    .frame(minWidth: 70)
                    .contentTransition(.numericText())

                Button(action: plus) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.fg0)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.ink1))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.ink3)
        )
    }
}
