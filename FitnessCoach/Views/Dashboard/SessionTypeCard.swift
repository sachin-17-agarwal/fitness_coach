// SessionTypeCard.swift
// FitnessCoach

import SwiftUI

/// Card showing today's session type with mesocycle info and a Start Workout button.
struct SessionTypeCard: View {
    let mesocycle: MesocycleState
    let onStartWorkout: () -> Void

    private var sessionIcon: String {
        switch mesocycle.todayType {
        case "Pull": return "arrow.down.to.line"
        case "Push": return "arrow.up.to.line"
        case "Legs": return "figure.walk"
        case "Cardio+Abs": return "heart.circle"
        case "Yoga": return "figure.mind.and.body"
        default: return "figure.strengthtraining.traditional"
        }
    }

    private var sessionColor: Color {
        switch mesocycle.todayType {
        case "Pull": return .recoveryGreen
        case "Push": return .recoveryYellow
        case "Legs": return .recoveryRed
        case "Cardio+Abs": return Color(hex: "FF6B6B")
        case "Yoga": return Color(hex: "6B9DFF")
        default: return .recoveryGreen
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Today's Session")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.textSecondary)

                    HStack(spacing: 10) {
                        Image(systemName: sessionIcon)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(sessionColor)

                        Text(mesocycle.todayType)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }

                    Text("Week \(mesocycle.week) \u{2022} Day \(mesocycle.day)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer()

                // Session type badge
                ZStack {
                    Circle()
                        .fill(sessionColor.opacity(0.15))
                        .frame(width: 56, height: 56)

                    Image(systemName: sessionIcon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(sessionColor)
                }
            }

            Button(action: onStartWorkout) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .semibold))

                    Text("Start Workout")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(sessionColor)
                .cornerRadius(12)
            }
        }
        .darkCard()
    }
}

#Preview {
    SessionTypeCard(
        mesocycle: MesocycleState(day: 2, week: 3)
    ) {
        print("Start workout")
    }
    .padding()
    .background(Color.background)
}
