// LiveStatsBar.swift
// Vaux
//
// Horizontal strip shown at the top of an active workout. Live stats with
// animated values — tonnage, sets logged, running duration, and live BPM
// streamed from HealthKit (when a heart-rate source is connected).

import SwiftUI

struct LiveStatsBar: View {
    let tonnage: Double
    let setCount: Int
    let duration: TimeInterval
    let heartRate: Int?

    var body: some View {
        HStack(spacing: 8) {
            stat(icon: "scalemass.fill", value: formatTonnage(tonnage), label: "TONNAGE", color: .accentPurple)
            divider
            stat(icon: "number", value: "\(setCount)", label: "SETS", color: .recoveryGreen)
            divider
            stat(icon: "timer", value: formatDuration(duration), label: "TIME", color: .accentAmber)
            divider
            heartRateStat
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            Rectangle()
                .fill(Color.surface)
                .overlay(
                    Rectangle()
                        .fill(Color.cardBorder.opacity(0.5))
                        .frame(height: 0.5),
                    alignment: .bottom
                )
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.cardBorder)
            .frame(width: 0.5, height: 26)
    }

    private func stat(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .kerning(0.8)
                    .foregroundStyle(Color.textTertiary)
            }
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }

    private var heartRateStat: some View {
        let color = heartRateColor(heartRate)
        let value = heartRate.map { "\($0)" } ?? "—"
        return VStack(spacing: 2) {
            HStack(spacing: 5) {
                HeartBeatIcon(isPulsing: heartRate != nil, color: color)
                Text("BPM")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .kerning(0.8)
                    .foregroundStyle(Color.textTertiary)
            }
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }

    private func heartRateColor(_ bpm: Int?) -> Color {
        guard let bpm else { return Color.textTertiary }
        switch bpm {
        case ..<100: return .mint
        case ..<140: return .amber
        default:     return .ember
        }
    }

    private func formatTonnage(_ t: Double) -> String {
        if t >= 1000 { return String(format: "%.1ft", t / 1000) }
        return "\(Int(t)) kg"
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

private struct HeartBeatIcon: View {
    let isPulsing: Bool
    let color: Color
    @State private var scale: CGFloat = 1.0

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .scaleEffect(scale)
            .onAppear { if isPulsing { startPulse() } }
            .onChange(of: isPulsing) { _, newValue in
                if newValue { startPulse() } else { scale = 1.0 }
            }
    }

    private func startPulse() {
        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
            scale = 1.18
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        LiveStatsBar(tonnage: 2450, setCount: 8, duration: 1834, heartRate: 132)
        LiveStatsBar(tonnage: 2450, setCount: 8, duration: 1834, heartRate: nil)
    }
    .background(Color.background)
}
