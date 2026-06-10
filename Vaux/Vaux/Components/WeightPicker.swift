// WeightPicker.swift
// FitnessCoach

import SwiftUI

/// Scrollable wheel picker for selecting weights in 0.5kg increments.
/// Designed for easy mid-workout use with large, clear numbers.
struct WeightPicker: View {
    @Binding var weight: Double

    /// Range of selectable weights.
    private let minWeight: Double = 0
    private let maxWeight: Double = 300
    private let step: Double = 0.5

    /// All weight options in 0.5kg increments.
    private var weightOptions: [Double] {
        stride(from: minWeight, through: maxWeight, by: step).map { $0 }
    }

    /// Index into weightOptions for the Picker selection.
    private var selectedIndex: Binding<Int> {
        Binding(
            get: {
                let idx = Int((weight - minWeight) / step)
                return min(max(idx, 0), weightOptions.count - 1)
            },
            set: { newIndex in
                weight = minWeight + Double(newIndex) * step
            }
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            // Display value
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(weight.wholeOrOne)
                    .font(.system(size: 44, weight: .light, design: .serif))
                    .foregroundStyle(Color.fg0)
                    .contentTransition(.numericText(value: weight))
                Text("kg")
                    .font(.serifSM)
                    .foregroundStyle(Color.fg2)
            }

            // Wheel picker
            Picker("Weight", selection: selectedIndex) {
                ForEach(0..<weightOptions.count, id: \.self) { index in
                    Text(weightOptions[index].wholeOrOne)
                        .tag(index)
                        .foregroundStyle(.white)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 120)

            // Quick adjustment buttons
            HStack(spacing: 16) {
                adjustButton(delta: -5.0, label: "-5")
                adjustButton(delta: -2.5, label: "-2.5")
                adjustButton(delta: -0.5, label: "-0.5")
                adjustButton(delta: +0.5, label: "+0.5")
                adjustButton(delta: +2.5, label: "+2.5")
                adjustButton(delta: +5.0, label: "+5")
            }
        }
    }

    private func adjustButton(delta: Double, label: String) -> some View {
        Button {
            Haptic.soft()
            let newWeight = weight + delta
            weight = min(max(newWeight, minWeight), maxWeight)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.fg0)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.ink3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.line2, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var weight: Double = 80.0
        var body: some View {
            WeightPicker(weight: $weight)
                .padding()
                .background(Color.background)
        }
    }
    return PreviewWrapper()
}
