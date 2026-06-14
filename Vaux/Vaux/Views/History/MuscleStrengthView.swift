// MuscleStrengthView.swift
// Vaux
//
// History → Strength tab. Shows how estimated 1RM is trending for each
// muscle group, a per-muscle strength table, and a "what's lacking"
// readout (stalled strength, low volume, neglect, push/pull imbalance).

import SwiftUI
import Charts

struct MuscleStrengthView: View {
    let viewModel: MuscleStrengthViewModel
    @State private var selectedGroup = ""

    var body: some View {
        VStack(spacing: 16) {
            if viewModel.muscles.isEmpty && viewModel.hasLoadedOnce {
                emptyState
            } else {
                lackingCard
                progressionCard
                strengthTableCard
            }
        }
    }

    // MARK: - What's lacking

    private var lackingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WHAT'S LACKING")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .kerning(1)
                        .foregroundStyle(Color.fg2)
                    Text("Stalled strength · low volume · neglect · imbalance")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.fg3)
                }
                Spacer()
                if !viewModel.lacking.isEmpty {
                    Text("\(viewModel.lacking.count) FLAGGED")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .kerning(0.8)
                        .foregroundStyle(Color.amber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.amber.opacity(0.12)))
                }
            }

            if viewModel.lacking.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.mint)
                    Text("Every muscle is progressing and trained on schedule.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.fg1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.lacking) { flag in
                        lackingRow(flag)
                    }
                }
            }
        }
        .darkCard(padding: 16, cornerRadius: 18)
    }

    private func lackingRow(_ flag: LackingFlag) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.amber)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.amber.opacity(0.6), radius: 4)
                Text(flag.group)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.fg0)
                Spacer(minLength: 0)
            }
            FlowChips(items: flag.reasons)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ink3.opacity(0.6))
        )
    }

    // MARK: - Progression chart

    private var effectiveGroup: String {
        if !selectedGroup.isEmpty, viewModel.chartableGroups.contains(selectedGroup) {
            return selectedGroup
        }
        return viewModel.chartableGroups.first ?? ""
    }

    private var selectedMuscle: MuscleStrength? {
        viewModel.muscles.first { $0.group == effectiveGroup }
    }

    private var progressionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow(text: "Strength trend")
                Spacer()
                if let best = selectedMuscle?.currentBest, best > 0 {
                    Text("\(Int(best.rounded())) kg")
                        .font(.numSM)
                        .foregroundStyle(Color.signal)
                }
            }
            Text("Best estimated 1RM per week · last 12 weeks")
                .font(.system(size: 11))
                .foregroundStyle(Color.fg3)

            if !viewModel.chartableGroups.isEmpty {
                groupPicker
            }

            if let series = selectedMuscle?.series, series.count >= 2 {
                chart(series)
            } else {
                Text(viewModel.chartableGroups.isEmpty
                     ? "LOG A FEW WEIGHTED SETS TO SEE STRENGTH TRENDS"
                     : "NOT ENOUGH DATA FOR \(effectiveGroup.uppercased())")
                    .font(.eyebrowSmall)
                    .kerning(1.2)
                    .foregroundStyle(Color.fg3)
                    .multilineTextAlignment(.center)
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
            }
        }
        .darkCard(padding: 16, cornerRadius: 18)
    }

    private var groupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.chartableGroups, id: \.self) { name in
                    let isSelected = effectiveGroup == name
                    Button {
                        Haptic.selection()
                        selectedGroup = name
                    } label: {
                        Text(name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.signal : Color.fg1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.signal.opacity(0.08) : Color.ink3)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isSelected ? Color.signal.opacity(0.22) : Color.line, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chart(_ series: [StrengthPoint]) -> some View {
        Chart(series) { point in
            LineMark(
                x: .value("Week", point.weekStart),
                y: .value("1RM", point.estimated1RM)
            )
            .foregroundStyle(Color.signal)
            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
            .interpolationMethod(.catmullRom)
            .shadow(color: Color.signal.opacity(0.45), radius: 4, y: 2)

            PointMark(
                x: .value("Week", point.weekStart),
                y: .value("1RM", point.estimated1RM)
            )
            .foregroundStyle(Color.signal)
            .symbolSize(point.id == series.last?.id ? 70 : 36)

            AreaMark(
                x: .value("Week", point.weekStart),
                y: .value("1RM", point.estimated1RM)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.signal.opacity(0.16), Color.signal.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel()
                    .foregroundStyle(Color.fg3)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                AxisGridLine()
                    .foregroundStyle(Color.line.opacity(0.7))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(Color.fg3)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
        }
        .frame(height: 170)
    }

    // MARK: - Per-muscle table

    private var strengthTableCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("STRENGTH BY MUSCLE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .kerning(1)
                    .foregroundStyle(Color.fg2)
                Text("Estimated 1RM and 12-week trend")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.fg3)
            }

            VStack(spacing: 12) {
                ForEach(viewModel.muscles) { muscle in
                    muscleRow(muscle)
                }
            }
        }
        .darkCard(padding: 16, cornerRadius: 18)
    }

    private func muscleRow(_ muscle: MuscleStrength) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(muscle.group)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.fg0)
                Text(subtitle(muscle))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.fg3)
            }
            Spacer(minLength: 0)
            Text(muscle.currentBest > 0 ? "\(Int(muscle.currentBest.rounded()))kg" : "—")
                .font(.system(size: 14, weight: .medium, design: .monospaced).monospacedDigit())
                .foregroundStyle(Color.fg0)
                .frame(minWidth: 56, alignment: .trailing)
            trendBadge(muscle.trendPct)
        }
    }

    private func subtitle(_ muscle: MuscleStrength) -> String {
        var parts: [String] = ["\(muscle.setsThisWeek) sets/wk"]
        if let days = muscle.daysSinceTrained {
            parts.append(days == 0 ? "today" : "\(days)d ago")
        } else {
            parts.append("untrained")
        }
        return parts.joined(separator: " · ")
    }

    private func trendBadge(_ pct: Double?) -> some View {
        let label: String
        let icon: String
        let color: Color
        if let pct {
            if pct >= 1 {
                label = MuscleStrengthViewModel.signedPct(pct); icon = "arrow.up.right"; color = .mint
            } else if pct <= -2 {
                label = MuscleStrengthViewModel.signedPct(pct); icon = "arrow.down.right"; color = .ember
            } else {
                label = "FLAT"; icon = "arrow.right"; color = .fg2
            }
        } else {
            label = "NEW"; icon = "sparkles"; color = .iris
        }
        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .kerning(0.5)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .frame(width: 64, alignment: .trailing)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            IconBadge(systemName: "chart.line.uptrend.xyaxis", accent: .signal, size: 64)
            Text("No strength data yet")
                .font(.serifSM)
                .foregroundStyle(Color.fg0)
            Text("LOG SOME WEIGHTED SETS AND YOUR PER-MUSCLE TRENDS APPEAR HERE")
                .font(.eyebrowSmall)
                .kerning(1.2)
                .foregroundStyle(Color.fg2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

/// Simple wrapping row of reason chips. Falls back to a vertical stack-free
/// flow so a muscle with several flags doesn't overflow the card width.
private struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlexibleWrap(spacing: 6, lineSpacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.amber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.amber.opacity(0.12)))
                    .overlay(Capsule().stroke(Color.amber.opacity(0.22), lineWidth: 1))
            }
        }
    }
}

/// Lightweight flow layout (iOS 16+) that wraps its subviews onto new lines
/// when they run out of horizontal room.
private struct FlexibleWrap: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !(rows[rows.count - 1].isEmpty) {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        let height = rows.reduce(CGFloat.zero) { acc, row in
            acc + (row.map(\.height).max() ?? 0) + lineSpacing
        } - lineSpacing
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
