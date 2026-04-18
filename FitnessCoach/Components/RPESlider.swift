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
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(rpeColor)

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
                                colors: [.recoveryGreen, .recoveryYellow, .recoveryRed],
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
                                colors: [.recoveryGreen, .recoveryYellow, .recoveryRed],
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
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let fraction = gesture.location.x / width
                            let clamped = min(max(fraction, 0), 1)
                            let raw = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
                            value = (raw / step).rounded() * step
                            value = min(max(value, range.lowerBound), range.upperBound)
                        }
                )
            }
            .frame(height: 28)

            // Step labels
            HStack {
                ForEach(Array(stride(from: 6.0, through: 10.0, by: 1.0)), id: \.self) { tick in
                    Text("\(Int(tick))")
                        .font(.caption2)
                        .foregroundStyle(Color.textSecondary)
                    if tick < 10.0 {
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var rpeColor: Color {
        let normalized = (value - 6.0) / 4.0
        if normalized <= 0.5 {
            return .recoveryGreen
        } else if normalized <= 0.75 {
            return .recoveryYellow
        } else {
            return .recoveryRed
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
