// RestTimer.swift
// Vaux
//
// Full-screen rest countdown ring with skip + add-15s controls.

import SwiftUI

struct RestTimer: View {
    let totalSeconds: Int
    @Binding var remainingSeconds: Int
    @Binding var isActive: Bool
    let onSkip: () -> Void

    @State private var timer: Timer?
    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()

            VStack(spacing: 22) {
                Text("REST")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .kerning(2.5)
                    .foregroundStyle(Color.textTertiary)

                ZStack {
                    Circle()
                        .stroke(ringColor.opacity(0.18), lineWidth: 10)
                        .frame(width: 220, height: 220)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .frame(width: 220, height: 220)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: remainingSeconds)
                        .shadow(color: ringColor.opacity(0.6), radius: 14, x: 0, y: 0)

                    VStack(spacing: 4) {
                        Text(timeString)
                            .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text(statusText)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .kerning(1)
                            .foregroundStyle(ringColor)
                    }
                }
                .scaleEffect(pulse ? 1.015 : 1.0)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)

                HStack(spacing: 10) {
                    Button {
                        Haptic.light()
                        remainingSeconds += 15
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("+15s")
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.surface))
                    }

                    Button {
                        Haptic.medium()
                        timer?.invalidate()
                        onSkip()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "forward.fill")
                            Text("Skip")
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.recoveryGreen))
                    }
                }
            }
        }
        .onAppear {
            pulse = true
            startTimer()
        }
        .onDisappear { timer?.invalidate() }
    }

    private var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1, max(0, Double(remainingSeconds) / Double(totalSeconds)))
    }

    private var ringColor: Color {
        if remainingSeconds <= 10 { return .recoveryRed }
        if remainingSeconds <= 30 { return .recoveryYellow }
        return .recoveryGreen
    }

    private var statusText: String {
        if remainingSeconds <= 10 { return "ALMOST" }
        if remainingSeconds <= 30 { return "GET READY" }
        return "RECOVER"
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
                Haptic.warning()
                isActive = false
            }
        }
    }
}
