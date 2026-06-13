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
    @State private var ripple = false

    var body: some View {
        ZStack {
            Color.ink0.opacity(0.94)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(Color.signal.opacity(0.25))
                        .frame(width: 160, height: 160)
                        .blur(radius: 40)

                    // Sonar ripples expanding outward from the badge
                    Circle()
                        .stroke(Color.signal.opacity(ripple ? 0 : 0.35), lineWidth: 1)
                        .frame(width: 130, height: 130)
                        .scaleEffect(ripple ? 1.85 : 1.0)
                    Circle()
                        .stroke(Color.signal.opacity(ripple ? 0 : 0.22), lineWidth: 1)
                        .frame(width: 130, height: 130)
                        .scaleEffect(ripple ? 1.45 : 1.0)

                    ZStack {
                        Circle()
                            .fill(Color.signal.opacity(0.10))
                            .frame(width: 130, height: 130)
                        Circle()
                            .stroke(Color.signal.opacity(0.45), lineWidth: 1)
                            .frame(width: 130, height: 130)
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 52, weight: .medium))
                            .foregroundStyle(Color.signal)
                    }
                    .scaleEffect(badgeScale)
                    .rotationEffect(.degrees(rotation))
                }

                VStack(spacing: 8) {
                    Text("NEW PR")
                        .font(.eyebrow)
                        .kerning(3)
                        .foregroundStyle(Color.signal)

                    Text(exercise)
                        .font(.serifMD)
                        .foregroundStyle(Color.fg0)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 8) {
                        Text("EST. 1RM")
                            .font(.eyebrowSmall)
                            .kerning(1.0)
                            .foregroundStyle(Color.fg2)
                        Text(estimated1RM.weightString)
                            .font(.numMD)
                            .foregroundStyle(Color.signal)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.signal.opacity(0.08))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.signal.opacity(0.22), lineWidth: 1)
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
            withAnimation(.easeOut(duration: 1.5).delay(0.25).repeatForever(autoreverses: false)) {
                ripple = true
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
