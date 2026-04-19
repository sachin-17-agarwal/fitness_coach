// WorkoutModeView.swift
// Vaux
//
// AI-driven workout screen with live stats, prescription card, set logging,
// rest timer, and inline coach chat.

import SwiftUI

struct WorkoutModeView: View {
    @State private var viewModel = WorkoutViewModel()
    var sessionType: String = ""

    var body: some View {
        ZStack {
            Color.background.ignoresSafeArea()

            if !viewModel.isActive && !viewModel.showSummary {
                startView
            } else {
                activeWorkoutView
            }

            if viewModel.isResting {
                RestTimer(
                    totalSeconds: 120,
                    remainingSeconds: $viewModel.restTimeRemaining,
                    isActive: $viewModel.isResting,
                    onSkip: { viewModel.skipRest() }
                )
                .transition(.opacity)
            }

            if viewModel.showPRCelebration, let pr = viewModel.latestPR {
                PRCelebration(
                    exercise: pr.exercise,
                    estimated1RM: pr.estimated1RM,
                    isShowing: $viewModel.showPRCelebration
                )
                .transition(.opacity)
            }
        }
        .navigationTitle(viewModel.isActive ? viewModel.sessionType : "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.isActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptic.warning()
                        Task { await viewModel.endWorkout() }
                    } label: {
                        Text("End")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.recoveryRed)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.recoveryRed.opacity(0.14)))
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showSummary) {
            if let summary = viewModel.summary {
                WorkoutSummaryView(summary: summary) {
                    viewModel.dismissSummary()
                }
            }
        }
    }

    // MARK: - Start screen

    private var startView: some View {
        let type = sessionType.isEmpty ? "Session" : sessionType
        let gradient = Gradients.forSession(type)
        let accent = Color.forSession(type)
        return VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(gradient)
                    .frame(width: 140, height: 140)
                    .blur(radius: 40)
                    .opacity(0.55)

                Circle()
                    .fill(gradient)
                    .frame(width: 110, height: 110)

                Image(systemName: iconForType(type))
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 8) {
                Text("Ready to train?")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.textSecondary)

                Text(sessionType.isEmpty ? "Start workout" : "\(sessionType) Day")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(focusForType(type))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textTertiary)
                    .padding(.top, 2)
            }

            Spacer()

            Button {
                Haptic.medium()
                Task { await viewModel.startWorkout(type: sessionType) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Begin session")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(gradient)
                )
                .shadow(color: accent.opacity(0.35), radius: 18, x: 0, y: 10)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Active workout

    private var activeWorkoutView: some View {
        VStack(spacing: 0) {
            LiveStatsBar(
                tonnage: viewModel.totalTonnage,
                setCount: viewModel.setCount,
                duration: viewModel.sessionDuration
            )

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if let lastCoach = viewModel.coachMessages.last(where: { !$0.isUser }) {
                        CoachMessageStrip(content: lastCoach.content)
                    }

                    if let rx = viewModel.currentPrescription {
                        PrescriptionCard(prescription: rx)
                    }

                    SetLogInput(
                        weight: $viewModel.inputWeight,
                        reps: $viewModel.inputReps,
                        rpe: $viewModel.inputRPE,
                        onLog: {
                            Haptic.medium()
                            Task { await viewModel.logSet() }
                        },
                        isLoading: viewModel.isLoading
                    )

                    if !viewModel.loggedSets.isEmpty {
                        SetProgressRow(sets: viewModel.loggedSets)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }

            InlineChatInput(
                text: $viewModel.inlineChatText,
                isExpanded: $viewModel.showInlineChat,
                onSend: { Task { await viewModel.sendInlineMessage() } },
                isLoading: viewModel.isLoading
            )
        }
    }

    // MARK: - Helpers

    private func iconForType(_ type: String) -> String {
        switch type {
        case "Pull": return "arrow.down.to.line"
        case "Push": return "dumbbell.fill"
        case "Legs": return "figure.strengthtraining.functional"
        case "Cardio+Abs": return "heart.circle.fill"
        case "Yoga": return "figure.mind.and.body"
        default: return "figure.strengthtraining.traditional"
        }
    }

    private func focusForType(_ type: String) -> String {
        switch type {
        case "Pull": return "Back · Rear delts · Biceps"
        case "Push": return "Chest · Shoulders · Triceps"
        case "Legs": return "Quads · Hamstrings · Glutes"
        case "Cardio+Abs": return "Zone 2 · Core"
        case "Yoga": return "Mobility · Stretching"
        default: return "Full body"
        }
    }
}

// MARK: - Coach message strip

struct CoachMessageStrip: View {
    let content: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CoachAvatar()
                Text("Coach says")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Button {
                    withAnimation(Motion.smooth) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.textSecondary)
                        .padding(6)
                        .background(Circle().fill(Color.surface))
                }
            }

            MarkdownText(content: content)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(expanded ? nil : 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Set progress row

struct SetProgressRow: View {
    let sets: [WorkoutSet]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LOGGED")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .kerning(1.0)
                    .foregroundStyle(Color.textTertiary)
                Spacer()
                Text("\(sets.count) set\(sets.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(sets.enumerated()), id: \.offset) { idx, set in
                        setChip(index: idx + 1, set: set)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.cardBorder, lineWidth: 0.5)
        )
    }

    private func setChip(index: Int, set: WorkoutSet) -> some View {
        let weight = set.actualWeightKg ?? set.targetWeightKg ?? 0
        let reps = set.actualReps ?? set.targetReps ?? 0
        let rpe = set.actualRpe ?? set.targetRpe
        return VStack(spacing: 3) {
            Text("SET \(index)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.textTertiary)
            Text("\(Int(weight))×\(reps)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            if let rpe {
                Text("RPE \(rpe.oneDecimal)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.recoveryGreen)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.surface)
        )
    }
}
