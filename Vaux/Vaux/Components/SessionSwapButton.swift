// SessionSwapButton.swift
// Vaux
//
// "Train something else today" — the escape hatch from the computed schedule.
//
// The rotation and the Sunday yoga rule between them decide every day's
// session, and until this existed that decision was final: a missed Saturday
// left the athlete on a yoga day with no way to reach the Legs session the
// rotation was sitting on. Settings couldn't help either, because its Day
// stepper moves the rotation position while the yoga rule keys off the actual
// weekday.
//
// Deliberately a swap for one day rather than an edit to the programme. The
// schedule is right almost always; what it lacked was give for the weeks it
// isn't.

import SwiftUI

struct SessionSwapButton: View {
    let currentType: String
    let isOverridden: Bool
    /// Passed the chosen session, or nil to restore the schedule.
    let onChange: (String?) -> Void

    /// Matches the surrounding screen — amber once a swap is in effect, so the
    /// card reads as deliberately off-schedule rather than as a mistake.
    var tint: Color { isOverridden ? .amber : .fg2 }

    @State private var showingPicker = false

    var body: some View {
        Button {
            Haptic.light()
            showingPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .bold))
                Text(isOverridden ? "CHANGED" : "CHANGE")
                    .font(.eyebrowSmall)
                    .kerning(1.2)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.10)))
            .overlay(Capsule().stroke(tint.opacity(0.25), lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change today's session")
        .accessibilityValue(currentType)
        .confirmationDialog("Today's session", isPresented: $showingPicker, titleVisibility: .visible) {
            ForEach(Config.selectableSessionTypes, id: \.self) { type in
                if type != currentType {
                    Button(type) {
                        Haptic.selection()
                        onChange(type)
                    }
                }
            }
            if isOverridden {
                Button("Back to schedule", role: .destructive) {
                    Haptic.light()
                    onChange(nil)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                isOverridden
                    ? "Swapped from your schedule for today only — back to normal tomorrow."
                    : "Changes today only. Tomorrow returns to your schedule."
            )
        }
    }
}
