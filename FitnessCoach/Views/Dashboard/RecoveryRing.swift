// RecoveryRing.swift
// FitnessCoach

import SwiftUI

/// Circular progress ring displaying recovery score (0-100).
/// Color adapts based on HRV relative to 7-day average:
/// green (>= avg), yellow (within 10% below), red (> 10% below).
struct RecoveryRing: View {
    let score: Int
    let level: DashboardViewModel.RecoveryLevel
    let statusText: String

    @State private var animatedScore: Int = 0
    @State private var glowPulse = false

    private var progress: Double {
        Double(score) / 100.0
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
        case .unknown: return "No Data"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.cardBorder, lineWidth: 14)
                    .frame(width: 180, height: 180)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .frame(width: 180, height: 180)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 1.0), value: progress)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        ringColor.opacity(glowPulse ? 0.4 : 0.2),
                        style: StrokeStyle(lineWidth: 24, lineCap: .round)
                    )
                    .frame(width: 180, height: 180)
                    .rotationEffect(.degrees(-90))
                    .blur(radius: glowPulse ? 10 : 6)
                    .animation(.easeInOut(duration: 1.0), value: progress)

                VStack(spacing: 4) {
                    Text("\(animatedScore)")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(value: Double(animatedScore)))

                    Text(statusLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ringColor)
                }
            }

            VStack(spacing: 2) {
                Text("Recovery")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
            animateScore()
        }
        .onChange(of: score) { animateScore() }
    }

    private func animateScore() {
        animatedScore = 0
        let steps = min(score, 60)
        let interval = 0.8 / Double(max(steps, 1))
        for i in 0...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * interval) {
                withAnimation(.easeOut(duration: interval)) {
                    animatedScore = Int(Double(score) * Double(i) / Double(steps))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut) { animatedScore = score }
        }
    }
}

#Preview {
    VStack(spacing: 30) {
        RecoveryRing(score: 85, level: .green, statusText: "HRV above average")
        RecoveryRing(score: 55, level: .yellow, statusText: "HRV slightly below avg")
        RecoveryRing(score: 30, level: .red, statusText: "HRV well below avg")
    }
    .padding()
    .background(Color.background)
}
