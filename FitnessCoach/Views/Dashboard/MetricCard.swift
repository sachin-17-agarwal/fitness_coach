// MetricCard.swift
// FitnessCoach

import SwiftUI

/// Reusable card displaying a single metric with icon, title, value,
/// optional subtitle, and optional trend indicator.
struct MetricCard: View {
    let icon: String
    let title: String
    let value: String
    var subtitle: String? = nil
    var trend: Trend? = nil
    var accentColor: Color = .white

    enum Trend {
        case up, down, flat

        var icon: String {
            switch self {
            case .up: return "arrow.up.right"
            case .down: return "arrow.down.right"
            case .flat: return "arrow.right"
            }
        }

        var color: Color {
            switch self {
            case .up: return .recoveryGreen
            case .down: return .recoveryRed
            case .flat: return .textSecondary
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accentColor)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.textSecondary)

                Spacer()

                if let trend {
                    Image(systemName: trend.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(trend.color)
                }
            }

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .darkCard()
    }
}

#Preview {
    VStack(spacing: 12) {
        MetricCard(
            icon: "moon.fill",
            title: "Sleep",
            value: "7.2h",
            subtitle: "Good quality",
            trend: .up,
            accentColor: .recoveryGreen
        )

        MetricCard(
            icon: "heart.fill",
            title: "Resting HR",
            value: "52 bpm",
            subtitle: "7-day avg: 54",
            trend: .down,
            accentColor: .recoveryRed
        )

        MetricCard(
            icon: "scalemass.fill",
            title: "Weight",
            value: "82.5 kg",
            trend: .flat
        )
    }
    .padding()
    .background(Color.background)
}
