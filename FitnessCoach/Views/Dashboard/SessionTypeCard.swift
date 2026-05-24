import SwiftUI

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

    private var sessionSubtitle: String {
        switch mesocycle.todayType {
        case "Pull": return "BACK \u{2022} BICEPS"
        case "Push": return "CHEST \u{2022} SHOULDERS \u{2022} TRICEPS"
        case "Legs": return "QUADS \u{2022} HAMSTRINGS \u{2022} GLUTES"
        case "Cardio+Abs": return "CONDITIONING \u{2022} CORE"
        case "Yoga": return "MOBILITY \u{2022} STRETCHING"
        default: return "TRAINING"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("TODAY'S SESSION")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Text("WEEK \(mesocycle.week) \u{2022} DAY \(mesocycle.day)")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Color.textSecondary)
            }

            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(sessionColor.opacity(0.12))
                        .frame(width: 48, height: 48)

                    Image(systemName: sessionIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(sessionColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(mesocycle.todayType)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(sessionSubtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer()

                Button(action: onStartWorkout) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Start")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(sessionColor)
                    .clipShape(Capsule())
                }
                .pressableButton()
            }
        }
        .darkCard()
    }
}

#Preview {
    SessionTypeCard(
        mesocycle: MesocycleState(day: 5, week: 1)
    ) {
        print("Start workout")
    }
    .padding()
    .background(Color.background)
}
