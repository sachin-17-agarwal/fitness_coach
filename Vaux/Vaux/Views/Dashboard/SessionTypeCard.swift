// SessionTypeCard.swift
// Vaux
//
// Today's session "mission card": mono header with week/day readout,
// serif session name + mono focus line, and a glowing signal Start CTA.

import SwiftUI

struct SessionTypeCard: View {
    let mesocycle: MesocycleState
    let onStartWorkout: () -> Void
    /// Swaps today's session for another, or restores the schedule when passed
    /// nil. Optional so the preview and any other caller can omit it.
    var onChangeSession: ((String?) -> Void)? = nil

    @State private var showingPicker = false

    private var sessionIcon: String {
        switch mesocycle.todayType {
        case "Pull": return "arrow.down.to.line"
        case "Push": return "dumbbell.fill"
        case "Legs": return "figure.strengthtraining.functional"
        case "Cardio+Abs": return "heart.circle.fill"
        case "Yoga": return "figure.mind.and.body"
        default: return "figure.strengthtraining.traditional"
        }
    }

    private var focus: String {
        switch mesocycle.todayType {
        case "Pull": return "BACK · REAR DELTS · BICEPS"
        case "Push": return "CHEST · SHOULDERS · TRICEPS"
        case "Legs": return "QUADS · HAMS · GLUTES"
        case "Cardio+Abs": return "ZONE 2 · CORE"
        case "Yoga": return "MOBILITY · STRETCHING"
        default: return "FULL BODY"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Eyebrow(text: mesocycle.isOverridden ? "Today · changed" : "Today's session")
                Spacer()
                if onChangeSession != nil {
                    changeButton
                }
                Text("W\(mesocycle.week) · D\(mesocycle.day)")
                    .font(.eyebrowSmall)
                    .kerning(1.2)
                    .foregroundStyle(Color.fg2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.ink1.opacity(0.8)))
                    .overlay(Capsule().stroke(Color.line, lineWidth: 1))
                    .accessibilityLabel("Week \(mesocycle.week), day \(mesocycle.day)")
            }

            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.signal.opacity(0.10))
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.signal.opacity(0.25), lineWidth: 1)
                    Image(systemName: sessionIcon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.signal)
                        .shadow(color: Color.signal.opacity(0.5), radius: 6)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text(mesocycle.todayType)
                        .font(.serifMD)
                        .foregroundStyle(Color.fg0)
                    Text(focus)
                        .font(.eyebrowSmall)
                        .kerning(1.2)
                        .foregroundStyle(Color.fg2)
                }

                Spacer()

                startButton
            }
        }
        .padding(18)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.ink2.opacity(0.94))
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [Color.signal.opacity(0.07), .clear],
                            center: .topTrailing,
                            startRadius: 10,
                            endRadius: 280
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.signal.opacity(0.30), Color.line],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
    }

    /// Opens the swap picker. The schedule is a plan, not a contract — a
    /// missed day has to be recoverable — and until this existed the computed
    /// session was the only session, with no setting anywhere to say otherwise.
    private var changeButton: some View {
        Button {
            Haptic.light()
            showingPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .bold))
                Text("CHANGE")
                    .font(.eyebrowSmall)
                    .kerning(1.2)
            }
            .foregroundStyle(mesocycle.isOverridden ? Color.amber : Color.fg2)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().fill((mesocycle.isOverridden ? Color.amber : Color.fg2).opacity(0.10))
            )
            .overlay(
                Capsule().stroke((mesocycle.isOverridden ? Color.amber : Color.fg2).opacity(0.25), lineWidth: 1)
            )
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change today's session")
        .accessibilityValue(mesocycle.todayType)
        .confirmationDialog("Today's session", isPresented: $showingPicker, titleVisibility: .visible) {
            ForEach(Config.selectableSessionTypes, id: \.self) { type in
                Button(type) {
                    Haptic.selection()
                    onChangeSession?(type)
                }
            }
            if mesocycle.isOverridden {
                Button("Back to schedule", role: .destructive) {
                    Haptic.light()
                    onChangeSession?(nil)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                mesocycle.isOverridden
                    ? "Swapped from the schedule for today only. It returns to normal tomorrow."
                    : "Changes today only. Tomorrow returns to your schedule."
            )
        }
    }

    private var startButton: some View {
        Button {
            Haptic.medium()
            onStartWorkout()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Start")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.signalInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.signal))
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    .blendMode(.plusLighter)
            )
            .shadow(color: Color.signal.opacity(0.35), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(PressScaleStyle(scale: 0.93))
    }
}

#Preview {
    VStack(spacing: 16) {
        SessionTypeCard(mesocycle: MesocycleState(day: 2, week: 3)) {}
        SessionTypeCard(mesocycle: MesocycleState(day: 3, week: 1)) {}
    }
    .padding()
    .background(Color.ink0)
}
