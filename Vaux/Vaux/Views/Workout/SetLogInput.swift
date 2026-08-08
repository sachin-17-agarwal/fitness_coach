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
    /// True for pull-ups, dips, hanging leg raises and friends, where the
    /// field holds weight ADDED to bodyweight. Without this the stepper
    /// reads a perfectly good bodyweight set as "0", which looks broken.
    var isBodyweight: Bool = false

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
                    minus: { weight = max(0, weight - 2.5) },
                    plus: { weight += 2.5 }
                )
                stepper(
                    label: "Reps",
                    value: "\(reps)",
                    accessibilityValue: "\(reps) reps",
                    minus: { reps = max(1, reps - 1) },
                    plus: { reps += 1 }
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
                            .font(.scaled(16, weight: .semibold, relativeTo: .headline))
                    }
                }
                .foregroundStyle(buttonTextColor)
                .frame(maxWidth: .infinity, minHeight: 44)
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
        let unitLabel = isBodyweight ? "Added weight" : "Weight"
        return VStack(spacing: 6) {
            Text(isBodyweight ? "ADDED KG" : "WEIGHT")
                .font(.eyebrowSmall)
                .kerning(1.0)
                .foregroundStyle(Color.fg2)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                StepperButton(
                    systemName: "minus",
                    accessibilityLabel: "Decrease \(unitLabel.lowercased()) by 2.5 kilograms",
                    action: minus
                )

                VStack(spacing: 3) {
                    TextField("0", value: $weight,
                              format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .focused($weightFieldFocused)
                        .font(.scaled(20, weight: .medium, design: .monospaced, relativeTo: .title3, cap: 30).monospacedDigit())
                        .foregroundStyle(Color.fg0)
                        .frame(minWidth: 70)
                        .onChange(of: weight) { _, newValue in
                            if newValue < 0 { weight = 0 }
                        }
                        .accessibilityLabel("\(unitLabel) in kilograms")

                    Rectangle()
                        .fill(weightFieldFocused ? phaseColor : Color.fg2.opacity(0.35))
                        .frame(width: 36, height: weightFieldFocused ? 2 : 1)
                        .animation(.easeOut(duration: 0.15), value: weightFieldFocused)
                        .accessibilityHidden(true)
                }

                StepperButton(
                    systemName: "plus",
                    accessibilityLabel: "Increase \(unitLabel.lowercased()) by 2.5 kilograms",
                    action: plus
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.ink3)
        )
    }

    private func stepper(
        label: String,
        value: String,
        accessibilityValue: String,
        minus: @escaping () -> Void,
        plus: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 6) {
            Text(label.uppercased())
                .font(.eyebrowSmall)
                .kerning(1.0)
                .foregroundStyle(Color.fg2)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                StepperButton(
                    systemName: "minus",
                    accessibilityLabel: "Decrease \(label.lowercased())",
                    action: minus
                )

                Text(value)
                    .font(.scaled(20, weight: .medium, design: .monospaced, relativeTo: .title3, cap: 30).monospacedDigit())
                    .foregroundStyle(Color.fg0)
                    .frame(minWidth: 70)
                    .contentTransition(.numericText())
                    .accessibilityLabel(label)
                    .accessibilityValue(accessibilityValue)

                StepperButton(
                    systemName: "plus",
                    accessibilityLabel: "Increase \(label.lowercased())",
                    action: plus
                )
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
