// WeeklyVolumeView.swift
// Vaux
//
// History → Volume tab. Daily tonnage chart with peak/average overlays,
// color-coded muscle group bars with weekly target ranges, and a
// week-over-week summary row.

import SwiftUI
import Charts

struct WeeklyVolumeView: View {
    let viewModel: WeeklyVolumeViewModel

    var body: some View {
        VStack(spacing: 16) {
            summaryCard
            insightsRow
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
                color: .iris,
                icon: "scalemass.fill"
            )
            metric(
                value: "\(viewModel.thisWeekSets)",
                label: "Working sets",
                color: .mint,
                icon: "number"
            )
            deltaCard
        }
    }

    private func metric(value: String, label: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textSecondary)

            RoundedRectangle(cornerRadius: 1.5)
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
    }

    private var deltaCard: some View {
        let delta = viewModel.tonnageDeltaPct
        let color: Color = (delta ?? 0) >= 0 ? .mint : .ember
        let icon = (delta ?? 0) >= 0 ? "arrow.up.right" : "arrow.down.right"
        let label: String = {
            guard let delta else { return "—" }
            return String(format: "%@%.0f%%", delta >= 0 ? "+" : "", delta)
        }()

        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(label)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("vs. last week")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textSecondary)

            RoundedRectangle(cornerRadius: 1.5)
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
    }

    // MARK: - Insights row

    private var peakDay: DayTonnage? {
        viewModel.tonnageByDay.max(by: { $0.tonnage < $1.tonnage })
    }

    private var trainingDays: Int {
        viewModel.tonnageByDay.filter { $0.tonnage > 0 }.count
    }

    private var avgPerTrainingDay: Double {
        guard trainingDays > 0 else { return 0 }
        return viewModel.thisWeekTonnage / Double(trainingDays)
    }

    @ViewBuilder
    private var insightsRow: some View {
        if !viewModel.tonnageByDay.allSatisfy({ $0.tonnage == 0 }) {
            HStack(spacing: 10) {
                insight(
                    icon: "trophy.fill",
                    label: "Peak day",
                    value: peakDay.map { dayName($0.date) } ?? "—",
                    sub: peakDay.map { $0.tonnage.weightString } ?? "",
                    color: .signal
                )
                insight(
                    icon: "calendar",
                    label: "Active days",
                    value: "\(trainingDays)",
                    sub: "of 7",
                    color: .mint
                )
                insight(
                    icon: "chart.bar.fill",
                    label: "Avg / day",
                    value: avgPerTrainingDay > 0 ? avgPerTrainingDay.weightString : "—",
                    sub: trainingDays > 0 ? "trained" : "",
                    color: .iris
                )
            }
        }
    }

    private func insight(icon: String, label: String, value: String, sub: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(color.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .kerning(0.6)
                    .foregroundStyle(Color.fg2)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.fg2)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
    }

    // MARK: - Daily tonnage chart

    private var avgTonnage: Double {
        let nonzero = viewModel.tonnageByDay.filter { $0.tonnage > 0 }
        guard !nonzero.isEmpty else { return 0 }
        return nonzero.reduce(0) { $0 + $1.tonnage } / Double(nonzero.count)
    }

    private var tonnageChartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TONNAGE BY DAY")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .kerning(1)
                        .foregroundStyle(Color.fg2)
                    Text("Working sets only")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.fg3)
                }
                Spacer()
                if avgTonnage > 0 {
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(Color.fg2)
                            .frame(width: 12, height: 1)
                        Text("avg \(avgTonnage.weightString)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.fg2)
                    }
                }
            }

            if viewModel.tonnageByDay.allSatisfy({ $0.tonnage == 0 }) {
                emptyChartPlaceholder
            } else {
                Chart(viewModel.tonnageByDay) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Tonnage", day.tonnage)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: day.tonnage == peakDay?.tonnage && day.tonnage > 0
                                ? [Color.signal, Color.signal.opacity(0.8)]
                                : [Color.iris.opacity(0.75), Color.iris.opacity(0.5)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(6)

                    if avgTonnage > 0 {
                        RuleMark(y: .value("Avg", avgTonnage))
                            .foregroundStyle(Color.fg2.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                            .foregroundStyle(Color.fg2)
                            .font(.system(size: 10, weight: .medium))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Color.line.opacity(0.5))
                        AxisValueLabel().foregroundStyle(Color.fg2)
                            .font(.system(size: 10))
                    }
                }
                .frame(height: 150)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
    }

    private var emptyChartPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 24))
                .foregroundStyle(Color.fg3)
            Text("No working sets in the last 7 days")
                .font(.system(size: 12))
                .foregroundStyle(Color.fg2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
    }

    // MARK: - Muscle groups

    private var muscleGroupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SETS PER MUSCLE GROUP")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .kerning(1)
                        .foregroundStyle(Color.fg2)
                    Text("Bars show weekly target range")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.fg3)
                }
                Spacer()
                Text("\(viewModel.thisWeekSets) TOTAL")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .kerning(0.8)
                    .foregroundStyle(Color.signal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.signal.opacity(0.12)))
            }

            if viewModel.setsByMuscleGroup.isEmpty {
                Text("No sets logged this week.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.fg3)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 12) {
                    ForEach(displayGroups) { group in
                        muscleRow(group: group)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
    }

    private var displayGroups: [MuscleGroupVolume] {
        viewModel.setsByMuscleGroup
    }

    private func muscleRow(group: MuscleGroupVolume) -> some View {
        let target = targetRange(for: group.group)
        let color = colorFor(group.group)
        let status = volumeStatus(sets: group.setCount, target: target)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(group.group.capitalized)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: status.icon)
                        .font(.system(size: 8, weight: .bold))
                    Text(status.label)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .kerning(0.5)
                }
                .foregroundStyle(status.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(status.color.opacity(0.12)))

                Text("\(group.setCount)")
                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 28, alignment: .trailing)
            }

            GeometryReader { geo in
                let maxSets = max(Double(target.upperBound) + 4, Double(group.setCount) + 2)
                let totalWidth = geo.size.width
                let targetStartX = totalWidth * CGFloat(target.lowerBound) / CGFloat(maxSets)
                let targetEndX = totalWidth * CGFloat(target.upperBound) / CGFloat(maxSets)
                let fillWidth = totalWidth * CGFloat(group.setCount) / CGFloat(maxSets)

                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.ink3)
                        .frame(height: 8)

                    // Target zone band
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.fg2.opacity(0.15))
                        .frame(width: targetEndX - targetStartX, height: 8)
                        .offset(x: targetStartX)

                    // Filled progress
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color, color.opacity(0.6)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth, height: 8)

                    // Target lower bound tick
                    Rectangle()
                        .fill(Color.fg2.opacity(0.6))
                        .frame(width: 1, height: 12)
                        .offset(x: targetStartX, y: -2)

                    // Target upper bound tick
                    Rectangle()
                        .fill(Color.fg2.opacity(0.6))
                        .frame(width: 1, height: 12)
                        .offset(x: targetEndX, y: -2)
                }
            }
            .frame(height: 12)

            HStack {
                Text("Target \(target.lowerBound)–\(target.upperBound) sets")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.fg3)
                Spacer()
            }
        }
    }

    // MARK: - Helpers

    private func dayName(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private func colorFor(_ group: String) -> Color {
        switch group.lowercased() {
        case "chest": return .amber
        case "back": return .iris
        case "shoulders": return .amber
        case "legs", "quads", "hamstrings", "glutes": return .ember
        case "biceps": return .iris
        case "triceps": return .amber
        case "abs", "core": return .mint
        case "rear delts": return .iris
        default: return .signal
        }
    }

    /// Weekly set ranges tuned for the Pull/Push/Legs/Cardio+Abs/Yoga
    /// rotation where each muscle is trained once per week. Hypertrophy
    /// guidelines that assume 2–3 weekly sessions per muscle don't apply
    /// here, so these targets describe a productive single-session dose.
    private func targetRange(for group: String) -> ClosedRange<Int> {
        switch group.lowercased() {
        case "legs", "quads", "hamstrings", "glutes": return 8...14
        case "back", "chest": return 6...12
        case "shoulders": return 4...8
        case "biceps", "triceps": return 3...6
        case "rear delts": return 2...5
        case "abs", "core": return 3...8
        default: return 4...10
        }
    }

    private struct VolumeStatus {
        let label: String
        let icon: String
        let color: Color
    }

    private func volumeStatus(sets: Int, target: ClosedRange<Int>) -> VolumeStatus {
        if sets < target.lowerBound {
            return VolumeStatus(label: "LOW", icon: "arrow.down", color: .ember)
        }
        if sets > target.upperBound {
            return VolumeStatus(label: "HIGH", icon: "arrow.up", color: .amber)
        }
        return VolumeStatus(label: "ON TARGET", icon: "checkmark", color: .mint)
    }
}
