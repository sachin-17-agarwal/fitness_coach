// PRCelebration.swift
// Vaux
//
// Full-screen overlay shown briefly when a new estimated 1RM beats history.

import SwiftUI

struct PRCelebration: View {
    let exercise: String
    let estimated1RM: Double
    @Binding var isShowing: Bool

    @State private var scale: CGFloat = 0.3
    @State private var opacity: Double = 0
    @State private var rotation: Double = -12
    @State private var badgeScale: CGFloat = 0.4

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.94), Color.accentPurple.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(Gradients.push)
                        .frame(width: 160, height: 160)
                        .blur(radius: 40)
                        .opacity(0.6)

                    ZStack {
                        Circle()
                            .fill(Gradients.push)
                            .frame(width: 130, height: 130)
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 52, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .scaleEffect(badgeScale)
                    .rotationEffect(.degrees(rotation))
                }

                VStack(spacing: 8) {
                    Text("NEW PR")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .kerning(3)
                        .foregroundStyle(Color.accentAmber)

                    Text(exercise)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 8) {
                        Text("Est. 1RM")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.textSecondary)
                        Text(estimated1RM.weightString)
                            .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.recoveryGreen)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
                    .padding(.top, 6)
                }
            }
            .scaleEffect(scale)
            .opacity(opacity)
        }
        .onAppear {
            Haptic.success()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) {
                scale = 1.0
                opacity = 1.0
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.5).delay(0.1)) {
                badgeScale = 1.0
                rotation = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                withAnimation(.easeOut(duration: 0.35)) {
                    opacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isShowing = false
                }
            }
        }
    }
}
