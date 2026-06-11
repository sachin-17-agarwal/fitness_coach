// SessionTypeCard.swift
// Vaux
//
// Today's session "mission card": mono header with week/day readout,
// serif session name + mono focus line, and a glowing signal Start CTA.

import SwiftUI

struct SessionTypeCard: View {
    let mesocycle: MesocycleState
    let onStartWorkout: () -> Void

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
            HStack {
                Eyebrow(text: "Today's session")
                Spacer()
                Text("W\(mesocycle.week) · D\(mesocycle.day)")
                    .font(.eyebrowSmall)
                    .kerning(1.2)
                    .foregroundStyle(Color.fg2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.ink1.opacity(0.8)))
                    .overlay(Capsule().stroke(Color.line, lineWidth: 1))
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
