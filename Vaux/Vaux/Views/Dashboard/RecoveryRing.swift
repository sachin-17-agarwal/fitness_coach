// RecoveryRing.swift
// Vaux
//
// Hero recovery card: large gradient ring + inline metric chips + trend line.

import SwiftUI

struct RecoveryRing: View {
    let score: Int
    let level: DashboardViewModel.RecoveryLevel
    let statusText: String
    var sleep: Double? = nil
    var hrv: Double? = nil
    var rhr: Double? = nil

    private var ringGradient: LinearGradient {
        Gradients.forRecovery(score)
    }

    private var ringColor: Color {
        switch level {
        case .green: return .recoveryGreen
        case .yellow: return .recoveryYellow
        case .red: return .recoveryRed
        case .unknown: return .textSecondary
        }
    }

    private var statusLabel: String {
        switch level {
        case .green: return "Recovered"
        case .yellow: return "Moderate"
        case .red: return "Low"
        case .unknown: return "No data"
        }
    }

    @State private var animatedProgress: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECOVERY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .kerning(1.2)
                        .foregroundStyle(Color.textSecondary)

                    Text(statusLabel)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                Spacer()
                ring
            }

            HStack(spacing: 10) {
                inlineChip(icon: "waveform.path.ecg", label: "HRV", value: format(hrv, unit: "ms"))
                inlineChip(icon: "moon.fill", label: "Sleep", value: formatSleep(sleep))
                inlineChip(icon: "heart.fill", label: "RHR", value: format(rhr, unit: "bpm"))
            }
        }
        .heroCard(accent: ringColor)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1)) {
                animatedProgress = Double(score) / 100.0
            }
        }
        .onChange(of: score) { _, newValue in
            withAnimation(.easeOut(duration: 0.9)) {
                animatedProgress = Double(newValue) / 100.0
            }
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(ringColor.opacity(0.14), lineWidth: 10)
                .frame(width: 120, height: 120)

            Circle()
                .trim(from: 0, to: animatedProgress)
                .stroke(ringGradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 120, height: 120)

            Circle()
                .trim(from: 0, to: animatedProgress)
                .stroke(ringColor.opacity(0.45), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 120, height: 120)
                .blur(radius: 10)

            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(score)))
                Text("%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.textSecondary)
                    .offset(y: -4)
            }
        }
    }

    private func inlineChip(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ringColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func format(_ v: Double?, unit: String) -> String {
        guard let v else { return "—" }
        return "\(Int(v))"
    }

    private func formatSleep(_ v: Double?) -> String {
        guard let v else { return "—" }
        let hours = Int(v)
        let minutes = Int((v - Double(hours)) * 60)
        return "\(hours)h\(minutes)"
    }
}

#Preview {
    VStack(spacing: 16) {
        RecoveryRing(score: 82, level: .green, statusText: "HRV above average",
                     sleep: 7.4, hrv: 58, rhr: 54)
        RecoveryRing(score: 55, level: .yellow, statusText: "HRV below baseline",
                     sleep: 6.1, hrv: 42, rhr: 60)
    }
    .padding()
    .background(Color.background)
}
