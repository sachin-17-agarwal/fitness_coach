// WorkoutDock.swift
// Vaux
//
// The set-logging dock, pinned above the tab bar so a set can be logged
// without scrolling. Weight and reps with ▲▼ (tap the weight to type it —
// not every load lands on the 2.5 kg grid), RPE as a typographic scale, and
// LOG SET, which fires on a half-second hold so a thumb resting on the dock
// while scrolling cannot log a set by mistake.

import SwiftUI

struct WorkoutDock: View {
    @Binding var weight: Double
    @Binding var reps: Int
    @Binding var rpe: Double
    let phase: SetPhase
    /// "WORKING SET 2 OF 2" — which set the dock is about to log.
    let setLabel: String
    let isBodyweight: Bool
    let isLoading: Bool
    let onLog: () -> Void
    let onAskCoach: () -> Void

    @FocusState private var weightFocused: Bool
    @GestureState private var isHolding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let holdDuration: Double = 0.5
    private var weightStep: Double { 2.5 }

    private var phaseColor: Color {
        switch phase {
        case .warmup: return .fg2
        case .working: return .mint
        case .backoff: return .amber
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    Circle().fill(phaseColor).frame(width: 6, height: 6)
                    EditorialEyebrow(text: "Log · \(setLabel)", color: phaseColor, size: 9.5, kerning: 2)
                }
                Spacer()
                EditorialEyebrow(text: "Tap weight to type", color: Editorial.muted, size: 8.5, kerning: 1.2)
            }

            HStack(alignment: .bottom) {
                weightValue
                Spacer()
                repsValue
                Spacer()
                if phase != .warmup {
                    rpeScale
                }
            }
            .padding(.top, 10)

            HStack(spacing: 10) {
                holdButton
                Button {
                    Haptic.light()
                    onAskCoach()
                } label: {
                    Circle()
                        .fill(Color.signal)
                        .frame(width: 10, height: 10)
                        .frame(width: 52, height: 52)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.ink2))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.line, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressScaleStyle(scale: 0.94))
                .accessibilityLabel("Ask coach")
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            Color.ink0
                .overlay(Rectangle().fill(Color.line).frame(height: 1), alignment: .top)
        )
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { weightFocused = false }
                    .font(.system(size: 16, weight: .semibold))
            }
        }
    }

    // MARK: - Values

    private var weightValue: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                TextField("0", value: $weight, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .focused($weightFocused)
                    .font(.display(26))
                    .foregroundStyle(Color.fg0)
                    .frame(minWidth: 48)
                    .fixedSize()
                    .onChange(of: weight) { _, new in if new < 0 { weight = 0 } }
                    .accessibilityLabel(isBodyweight ? "Added weight in kilograms" : "Weight in kilograms")
                EditorialEyebrow(text: isBodyweight ? "+kg" : "kg", color: Editorial.muted, size: 8.5, kerning: 1)
            }
            arrows(
                up: { weight += weightStep },
                down: { weight = max(0, weight - weightStep) },
                label: "weight"
            )
        }
    }

    private var repsValue: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(reps)")
                    .font(.display(26))
                    .foregroundStyle(Color.fg0)
                    .contentTransition(.numericText())
                EditorialEyebrow(text: "reps", color: Editorial.muted, size: 8.5, kerning: 1)
            }
            arrows(
                up: { reps += 1 },
                down: { reps = max(1, reps - 1) },
                label: "reps"
            )
        }
    }

    private func arrows(up: @escaping () -> Void, down: @escaping () -> Void, label: String) -> some View {
        VStack(spacing: 2) {
            Button {
                Haptic.selection()
                withAnimation(Motion.snappy) { up() }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.fg2)
                    .frame(width: 28, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Increase \(label)")
            Button {
                Haptic.selection()
                withAnimation(Motion.snappy) { down() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.fg2)
                    .frame(width: 28, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decrease \(label)")
        }
    }

    /// 6 … 10 as digits, the chosen one lime and larger. No boxes, no slider.
    private var rpeScale: some View {
        let chosen = Int(rpe.rounded())
        return VStack(alignment: .trailing, spacing: 6) {
            EditorialEyebrow(text: "RPE", color: Editorial.muted, size: 8.5, kerning: 1)
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                ForEach(6...10, id: \.self) { value in
                    Button {
                        Haptic.selection()
                        withAnimation(Motion.snappy) { rpe = Double(value) }
                    } label: {
                        Text("\(value)")
                            .font(.display(value == chosen ? 26 : 18))
                            .foregroundStyle(value == chosen ? Color.signal : Color.ink4)
                            .frame(minWidth: 18, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("RPE \(value)")
                    .accessibilityAddTraits(value == chosen ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - Hold to log

    private var holdButton: some View {
        let holdGesture = LongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 30)
            .updating($isHolding) { current, state, _ in state = current }
            .onEnded { _ in
                Haptic.medium()
                onLog()
            }
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.ink3)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.line, lineWidth: 1))
            // The fill runs the width of the button over the hold; releasing
            // early lets it fall back, and only a completed hold logs.
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.signal)
                    .frame(width: isHolding ? geo.size.width : 0)
                    .animation(
                        reduceMotion ? nil : (isHolding ? .linear(duration: Self.holdDuration) : .easeOut(duration: 0.18)),
                        value: isHolding
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView().tint(Color.fg0).scaleEffect(0.85)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                    Text("LOG SET")
                        .font(.display(21))
                        .kerning(0.6)
                }
            }
            .foregroundStyle(isHolding ? Color.signalInk : Color.fg0)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: isHolding)
        }
        .frame(height: 52)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .gesture(holdGesture)
        .opacity(isLoading ? 0.6 : 1)
        .allowsHitTesting(!isLoading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Log set")
        .accessibilityHint("Press and hold for half a second to log \(weight.wholeOrOne) by \(reps)")
        .accessibilityAddTraits(.isButton)
    }
}
