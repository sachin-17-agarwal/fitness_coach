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
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("kg")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.textSecondary)
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
            let newWeight = weight + delta
            weight = min(max(newWeight, minWeight), maxWeight)
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.cardBorder)
                .cornerRadius(8)
        }
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
