// RPESlider.swift
// FitnessCoach

import SwiftUI

/// Custom slider for Rate of Perceived Exertion (RPE) values.
/// Supports 6.0 to 10.0 in 0.5 increments with a color gradient
/// from green (easy) through yellow (moderate) to red (hard).
struct RPESlider: View {
    @Binding var value: Double

    private let range: ClosedRange<Double> = 6.0...10.0
    private let step: Double = 0.5

    var body: some View {
        VStack(spacing: 12) {
            // Current value display
            Text("RPE \(value.oneDecimal)")
                .font(.system(size: 26, weight: .medium, design: .monospaced).monospacedDigit())
                .foregroundStyle(rpeColor)
                .contentTransition(.numericText(value: value))

            // Custom slider track
            GeometryReader { geometry in
                let width = geometry.size.width
                let normalizedValue = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let thumbX = normalizedValue * width

                ZStack(alignment: .leading) {
                    // Background track with gradient
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [.mint, .amber, .ember],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 12)
                        .opacity(0.3)

                    // Filled portion
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [.mint, .amber, .ember],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, thumbX), height: 12)

                    // Thumb
                    Circle()
                        .fill(rpeColor)
                        .frame(width: 28, height: 28)
                        .shadow(color: rpeColor.opacity(0.4), radius: 4)
                        .offset(x: max(0, thumbX - 14))
                }
                // The drawn track is 28pt tall, under the 44pt minimum, and
                // this is dragged once per set with a bar still in hand. The
                // hit area is grown to 44 around the unchanged visuals so the
                // grab region matches the intent rather than the artwork.
                .frame(height: 44)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let fraction = gesture.location.x / width
                            let clamped = min(max(fraction, 0), 1)
                            let raw = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
                            let stepped = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
                            // Only a change worth feeling gets a tick, so a
                            // slow drag doesn't buzz continuously.
                            if stepped != value {
                                Haptic.selection()
                                value = stepped
                            }
                        }
                )
            }
            .frame(height: 44)

            // Step labels
            HStack {
                ForEach(Array(stride(from: 6.0, through: 10.0, by: 1.0)), id: \.self) { tick in
                    Text("\(Int(tick))")
                        .font(.eyebrowSmall)
                        .foregroundStyle(Color.fg2)
                    if tick < 10.0 {
                        Spacer()
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
        // A bare DragGesture is unreachable with VoiceOver — there is no
        // pointer to drag. Collapsing the control into one adjustable element
        // gives it the standard swipe-up/down increment instead, which is how
        // a UISlider behaves and the only way this value can be set at all
        // without sighted touch.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rate of perceived exertion")
        .accessibilityValue("\(value.oneDecimal) out of 10")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = min(range.upperBound, value + step)
            case .decrement:
                value = max(range.lowerBound, value - step)
            @unknown default:
                break
            }
        }
    }

    private var rpeColor: Color {
        let normalized = (value - 6.0) / 4.0
        if normalized <= 0.5 {
            return .mint
        } else if normalized <= 0.75 {
            return .amber
        } else {
            return .ember
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var rpe = 8.0
        var body: some View {
            RPESlider(value: $rpe)
                .padding()
                .background(Color.background)
        }
    }
    return PreviewWrapper()
}
