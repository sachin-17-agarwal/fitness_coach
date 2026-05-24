import SwiftUI

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
            case .flat: return "minus"
            }
        }

        var label: String {
            switch self {
            case .up: return "UP"
            case .down: return "DOWN"
            case .flat: return "FLAT"
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(accentColor.opacity(0.15))
                        .frame(width: 30, height: 30)

                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accentColor)
                }

                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Color.textSecondary)

                Spacer()

                if let trend {
                    HStack(spacing: 3) {
                        Image(systemName: trend.icon)
                            .font(.system(size: 9, weight: .bold))
                        Text(trend.label)
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(trend.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(trend.color.opacity(0.12))
                    .clipShape(Capsule())
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if let subtitle {
                Text(subtitle.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard()
    }
}

#Preview {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        MetricCard(
            icon: "moon.fill",
            title: "SLEEP",
            value: "6:09",
            subtitle: "Moderate",
            accentColor: Color(hex: "6B9DFF")
        )

        MetricCard(
            icon: "heart.fill",
            title: "RESTING HR",
            value: "58 bpm",
            subtitle: "7d avg 57 bpm",
            trend: .flat,
            accentColor: .recoveryRed
        )

        MetricCard(
            icon: "scalemass.fill",
            title: "WEIGHT",
            value: "84.2 kg",
            subtitle: "18.6% body fat",
            accentColor: .recoveryYellow
        )

        MetricCard(
            icon: "figure.walk",
            title: "STEPS",
            value: "8.2k",
            accentColor: .recoveryGreen
        )
    }
    .padding()
    .background(Color.background)
}
