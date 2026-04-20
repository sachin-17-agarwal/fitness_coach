// VauxLogo.swift
// Vaux — editorial redesign
//
// Notched V mark: two diagonal arms meeting at a shortened apex so the
// negative space reads as a precise geometric shape rather than a letter.
// Single-weight, single-tone (fg-0 by default, switchable to signal).

import SwiftUI

struct VauxLogo: View {
    var size: CGFloat = 24
    var color: Color = .fg0

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
            .fill(color)
            .frame(width: size, height: size)
    }
}

struct VauxWordmark: View {
    var iconSize: CGFloat = 22
    var fontSize: CGFloat = 22
    var color: Color = .fg0

    var body: some View {
        HStack(spacing: 8) {
            VauxLogo(size: iconSize, color: color)
            Text("VAUX")
                .font(.system(size: fontSize, weight: .semibold))
                .kerning(2)
                .foregroundStyle(color)
        }
    }
}

struct VauxBrandFooter: View {
    var body: some View {
        VStack(spacing: 6) {
            VauxLogo(size: 20, color: .fg2)
            Text("VAUX")
                .font(.eyebrow)
                .kerning(2)
                .foregroundStyle(Color.fg2)
            Text("AI FITNESS COACH")
                .font(.eyebrowSmall)
                .kerning(1.4)
                .foregroundStyle(Color.fg3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

#Preview {
    VStack(spacing: 40) {
        VauxLogo(size: 80)
        VauxLogo(size: 40, color: .signal)
        VauxWordmark()
        VauxBrandFooter()
    }
    .padding()
    .background(Color.ink0)
}
