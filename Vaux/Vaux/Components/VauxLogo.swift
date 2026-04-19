// VauxLogo.swift
// Vaux

import SwiftUI

struct VauxLogo: View {
    var size: CGFloat = 40

    private var vShape: Path {
        let w = size
        let h = size
        let pad = w * 0.08

        let outerLeft = CGPoint(x: pad, y: pad)
        let outerRight = CGPoint(x: w - pad, y: pad)
        let bottomLeft = CGPoint(x: w * 0.45, y: h - pad)
        let bottomRight = CGPoint(x: w * 0.55, y: h - pad)

        let armWidth = w * 0.22
        let innerLeft = CGPoint(x: pad + armWidth, y: pad)
        let innerRight = CGPoint(x: w - pad - armWidth, y: pad)
        let innerBottom = CGPoint(x: w * 0.5, y: h - pad - h * 0.21)

        var path = Path()
        path.move(to: outerLeft)
        path.addLine(to: bottomLeft)
        path.addLine(to: bottomRight)
        path.addLine(to: outerRight)
        path.addLine(to: innerRight)
        path.addLine(to: innerBottom)
        path.addLine(to: innerLeft)
        path.closeSubpath()
        return path
    }

    var body: some View {
        vShape
            .fill(Gradients.recovery)
            .frame(width: size, height: size)
    }
}

struct VauxWordmark: View {
    var iconSize: CGFloat = 28
    var fontSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 8) {
            VauxLogo(size: iconSize)
            Text("VAUX")
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .kerning(2)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, .white.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }
}

struct VauxBrandFooter: View {
    var body: some View {
        VStack(spacing: 6) {
            VauxLogo(size: 24)
            Text("VAUX")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .kerning(2)
                .foregroundStyle(Color.textTertiary)
            Text("AI Fitness Coach")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.textTertiary.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

#Preview {
    VStack(spacing: 40) {
        VauxLogo(size: 80)
        VauxWordmark()
        VauxBrandFooter()
    }
    .padding()
    .background(Color.background)
}
