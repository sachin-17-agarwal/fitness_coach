import SwiftUI

struct RecoveryRing: View {
    let score: Int
    let level: DashboardViewModel.RecoveryLevel

    @State private var animatedProgress: Double = 0
    @State private var glowPulse = false

    private var targetProgress: Double {
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

    private var zoneName: String {
        switch level {
        case .green: return "GREEN"
        case .yellow: return "AMBER"
        case .red: return "RED"
        case .unknown: return "---"
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.cardBorder, lineWidth: 10)
                .frame(width: 130, height: 130)

            Circle()
                .trim(from: 0, to: animatedProgress)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .frame(width: 130, height: 130)
                .rotationEffect(.degrees(-90))

            Circle()
                .trim(from: 0, to: animatedProgress)
                .stroke(
                    ringColor.opacity(glowPulse ? 0.35 : 0.15),
                    style: StrokeStyle(lineWidth: 20, lineCap: .round)
                )
                .frame(width: 130, height: 130)
                .rotationEffect(.degrees(-90))
                .blur(radius: 8)

            VStack(spacing: 2) {
                Text("ZONE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.textSecondary)
                Text(zoneName)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(ringColor)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2)) {
                animatedProgress = targetProgress
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
        .onChange(of: score) {
            withAnimation(.easeOut(duration: 0.8)) {
                animatedProgress = targetProgress
            }
        }
    }
}

#Preview {
    HStack(spacing: 30) {
        RecoveryRing(score: 85, level: .green)
        RecoveryRing(score: 55, level: .yellow)
        RecoveryRing(score: 30, level: .red)
    }
    .padding()
    .background(Color.background)
}
