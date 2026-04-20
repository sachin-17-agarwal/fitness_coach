// SessionTypeCard.swift
// Vaux — editorial redesign
//
// Hairline card: session icon tile + serif lift name + mono focus line +
// full-width signal "Start" button. Quiet, no accent-tinted shadows.

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
                Eyebrow(text: "Week \(mesocycle.week) · Day \(mesocycle.day)")
            }

            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.signal.opacity(0.12))
                    Image(systemName: sessionIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.signal)
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
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.signal))
        }
        .buttonStyle(.plain)
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
