// SessionTypeCard.swift
// Vaux

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

    private var sessionGradient: LinearGradient {
        Gradients.forSession(mesocycle.todayType)
    }

    private var sessionColor: Color {
        Color.forSession(mesocycle.todayType)
    }

    private var focus: String {
        switch mesocycle.todayType {
        case "Pull": return "Back · Rear delts · Biceps"
        case "Push": return "Chest · Shoulders · Triceps"
        case "Legs": return "Quads · Hamstrings · Glutes"
        case "Cardio+Abs": return "Zone 2 · Core"
        case "Yoga": return "Mobility · Stretching"
        default: return "Full body"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("TODAY'S SESSION")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .kerning(1.2)
                    .foregroundStyle(Color.white.opacity(0.7))
                Spacer()
                Text("Week \(mesocycle.week) · Day \(mesocycle.day)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.7))
            }

            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: sessionIcon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(mesocycle.todayType)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(focus)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }

                Spacer()
            }

            Button(action: {
                Haptic.medium()
                onStartWorkout()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("Start workout")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.95))
                )
            }
        }
        .accentCard(sessionGradient, padding: 18, cornerRadius: 24)
        .shadow(color: sessionColor.opacity(0.3), radius: 24, x: 0, y: 14)
    }
}

#Preview {
    VStack(spacing: 16) {
        SessionTypeCard(mesocycle: MesocycleState(day: 2, week: 3)) {}
        SessionTypeCard(mesocycle: MesocycleState(day: 3, week: 1)) {}
        SessionTypeCard(mesocycle: MesocycleState(day: 5, week: 2)) {}
    }
    .padding()
    .background(Color.background)
}
