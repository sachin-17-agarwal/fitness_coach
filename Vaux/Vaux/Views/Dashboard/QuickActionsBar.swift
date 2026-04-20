// QuickActionsBar.swift
// Vaux
//
// Primary "Workout" CTA + compact icon-only secondary actions.

import SwiftUI

struct QuickActionsBar: View {
    let onWorkout: () -> Void
    let onChat: () -> Void
    let onLogWeight: () -> Void
    let onSync: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Primary action
            Button {
                Haptic.medium()
                onWorkout()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Workout")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Gradients.recovery)
                )
                .shadow(color: Color.recoveryGreen.opacity(0.38), radius: 14, x: 0, y: 6)
            }

            // Secondary icon-only actions
            iconButton(icon: "message.fill",  tint: .accentTeal,   action: onChat)
            iconButton(icon: "scalemass.fill", tint: .accentAmber,  action: onLogWeight)
            iconButton(icon: "arrow.clockwise", tint: .accentPurple, action: onSync)
        }
    }

    private func iconButton(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptic.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 50, height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(tint.opacity(0.22), lineWidth: 0.6)
                )
        }
    }
}

#Preview {
    QuickActionsBar(onWorkout: {}, onChat: {}, onLogWeight: {}, onSync: {})
        .padding()
        .background(Color.background)
}
