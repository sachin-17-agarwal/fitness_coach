import SwiftUI

struct RestTimer: View {
    let totalSeconds: Int
    @Binding var remainingSeconds: Int
    @Binding var isActive: Bool
    let onSkip: () -> Void

    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(Color.cardBorder, lineWidth: 8)
                        .frame(width: 180, height: 180)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(timerColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 180, height: 180)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: remainingSeconds)

                    VStack(spacing: 4) {
                        Text(timeString)
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("REST")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.gray)
                    }
                }

                Button(action: onSkip) {
                    Text("Skip")
                        .font(.headline)
                        .foregroundColor(.gray)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 10)
                        .background(Color.cardBackground)
                        .clipShape(Capsule())
                }
            }
        }
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
    }

    private var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(remainingSeconds) / Double(totalSeconds)
    }

    private var timerColor: Color {
        if remainingSeconds <= 10 { return Color.recoveryRed }
        if remainingSeconds <= 30 { return Color.recoveryYellow }
        return Color.recoveryGreen
    }

    private var timeString: String {
        let m = remainingSeconds / 60
        let s = remainingSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if remainingSeconds > 0 {
                remainingSeconds -= 1
            } else {
                timer?.invalidate()
                isActive = false
            }
        }
    }
}
