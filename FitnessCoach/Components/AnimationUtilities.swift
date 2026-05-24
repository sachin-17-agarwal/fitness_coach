import SwiftUI

// MARK: - Staggered Appearance

struct StaggeredAppearance: ViewModifier {
    let index: Int
    let delay: Double

    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 12)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(index) * delay)) {
                    isVisible = true
                }
            }
    }
}

extension View {
    func staggeredAppearance(index: Int, delay: Double = 0.05) -> some View {
        modifier(StaggeredAppearance(index: index, delay: delay))
    }
}

// MARK: - Pressable Button

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension View {
    func pressableButton() -> some View {
        buttonStyle(PressableButtonStyle())
    }
}

// MARK: - Shimmer Effect

struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.08), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: phase * geo.size.width)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: false)) {
                            phase = 1.5
                        }
                    }
                }
            )
            .clipped()
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerEffect())
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var dotOffsets: [CGFloat] = [0, 0, 0]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.recoveryGreen.opacity(0.8))
                    .frame(width: 8, height: 8)
                    .offset(y: dotOffsets[index])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { startAnimation() }
    }

    private func startAnimation() {
        for i in 0..<3 {
            withAnimation(
                .easeInOut(duration: 0.5)
                .repeatForever(autoreverses: true)
                .delay(Double(i) * 0.15)
            ) {
                dotOffsets[i] = -6
            }
        }
    }
}

// MARK: - Confetti Particle

struct ConfettiParticle: View {
    let color: Color
    @State private var xOffset: CGFloat = 0
    @State private var yOffset: CGFloat = 0
    @State private var opacity: Double = 1
    @State private var rotation: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 6, height: 10)
            .rotationEffect(.degrees(rotation))
            .offset(x: xOffset, y: yOffset)
            .opacity(opacity)
            .onAppear {
                let randomX = CGFloat.random(in: -120...120)
                let randomY = CGFloat.random(in: -200 ... -60)
                let randomRotation = Double.random(in: 0...720)

                withAnimation(.easeOut(duration: 1.5)) {
                    xOffset = randomX
                    yOffset = randomY + 300
                    opacity = 0
                    rotation = randomRotation
                }
            }
    }
}

struct ConfettiView: View {
    let colors: [Color] = [.recoveryGreen, .recoveryYellow, .white, Color(hex: "6B9DFF")]

    var body: some View {
        ZStack {
            ForEach(0..<20, id: \.self) { _ in
                ConfettiParticle(color: colors.randomElement() ?? .white)
            }
        }
    }
}

// MARK: - Pulse Glow

struct PulseGlow: ViewModifier {
    let color: Color
    let isActive: Bool
    @State private var glowing = false

    func body(content: Content) -> some View {
        content
            .shadow(color: isActive ? color.opacity(glowing ? 0.6 : 0.2) : .clear, radius: glowing ? 12 : 6)
            .onAppear {
                guard isActive else { return }
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    glowing = true
                }
            }
    }
}

extension View {
    func pulseGlow(color: Color, isActive: Bool = true) -> some View {
        modifier(PulseGlow(color: color, isActive: isActive))
    }
}
