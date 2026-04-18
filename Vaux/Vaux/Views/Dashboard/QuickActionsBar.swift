// QuickActionsBar.swift
// Vaux
//
// Horizontal row of pill-shaped quick actions shown below the recovery hero.

import SwiftUI

struct QuickActionsBar: View {
    let onBriefing: () -> Void
    let onChat: () -> Void
    let onLogWeight: () -> Void
    let onSync: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            action(icon: "sparkles", label: "Briefing", tint: .accentPurple, action: onBriefing)
            action(icon: "message.fill", label: "Chat", tint: .accentTeal, action: onChat)
            action(icon: "scalemass.fill", label: "Weight", tint: .accentAmber, action: onLogWeight)
            action(icon: "arrow.clockwise", label: "Sync", tint: .recoveryGreen, action: onSync)
        }
    }

    private func action(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptic.light()
            action()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    QuickActionsBar(onBriefing: {}, onChat: {}, onLogWeight: {}, onSync: {})
        .padding()
        .background(Color.background)
}
