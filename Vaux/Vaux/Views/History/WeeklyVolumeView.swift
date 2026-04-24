// WeeklyVolumeView.swift
// Vaux
//
// History → Volume tab. Shows trailing 7-day tonnage as a daily bar
// chart, sets-per-muscle-group as a horizontal list, and a
// week-over-week tonnage delta chip.

import SwiftUI
import Charts

struct WeeklyVolumeView: View {
    let viewModel: WeeklyVolumeViewModel

    var body: some View {
        VStack(spacing: 16) {
            summaryCard
            tonnageChartCard
            muscleGroupCard
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        HStack(spacing: 10) {
            metric(
                value: viewModel.thisWeekTonnage.weightString,
                label: "Tonnage",
                color: .accentPurple,
                icon: "scalemass.fill"
            )
            metric(
                value: "\(viewModel.thisWeekSets)",
                label: "Working sets",
                color: .recoveryGreen,
                icon: "number"
            )
            deltaCard
        }
    }

    private func metric(value: String, label: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Circle().fill(color.opacity(0.14)).frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 14, cornerRadius: 16)
    }

    private var deltaCard: some View {
        let delta = viewModel.tonnageDeltaPct
        let color: Color = (delta ?? 0) >= 0 ? .recoveryGreen : .recoveryRed
        let icon = (delta ?? 0) >= 0 ? "arrow.up.right" : "arrow.down.right"
        let label: String = {
            guard let delta else { return "—" }
            return String(format: "%@%.0f%%", delta >= 0 ? "+" : "", delta)
        }()

        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Circle().fill(color.opacity(0.14)).frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(label)
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("vs. last week")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 14, cornerRadius: 16)
    }

    // MARK: - Daily tonnage chart

    private var tonnageChartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TONNAGE BY DAY")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .kerning(1)
                    .foregroundStyle(Color.textTertiary)
                Spacer()
                Text("Last 7 days")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }

            if viewModel.tonnageByDay.allSatisfy({ $0.tonnage == 0 }) {
                emptyChartPlaceholder
            } else {
                Chart(viewModel.tonnageByDay) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Tonnage", day.tonnage)
                    )
                    .foregroundStyle(Color.signal)
                    .cornerRadius(4)
                }
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Color.cardBorder.opacity(0.4))
                        AxisValueLabel().foregroundStyle(Color.textTertiary)
                    }
                }
                .frame(height: 140)
            }
        }
        .darkCard(padding: 14, cornerRadius: 16)
    }

    private var emptyChartPlaceholder: some View {
        HStack {
            Spacer()
            Text("No working sets logged in the last week.")
                .font(.system(size: 12))
                .foregroundStyle(Color.textTertiary)
            Spacer()
        }
        .frame(height: 140)
    }

    // MARK: - Muscle groups

    private var muscleGroupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SETS PER MUSCLE GROUP")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .kerning(1)
                    .foregroundStyle(Color.textTertiary)
                Spacer()
                Text("\(viewModel.thisWeekSets) total")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }

            if viewModel.setsByMuscleGroup.isEmpty {
                Text("No sets logged this week.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
                    .padding(.vertical, 6)
            } else {
                let max = viewModel.setsByMuscleGroup.map(\.setCount).max() ?? 1
                VStack(spacing: 8) {
                    ForEach(viewModel.setsByMuscleGroup) { group in
                        muscleRow(group: group, max: max)
                    }
                }
            }
        }
        .darkCard(padding: 14, cornerRadius: 16)
    }

    private func muscleRow(group: MuscleGroupVolume, max: Int) -> some View {
        HStack(spacing: 10) {
            Text(group.group.capitalized)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 90, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.surface)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.signal)
                        .frame(width: max > 0 ? geo.size.width * CGFloat(group.setCount) / CGFloat(max) : 0)
                }
            }
            .frame(height: 8)

            Text("\(group.setCount)")
                .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 28, alignment: .trailing)
        }
    }
}
