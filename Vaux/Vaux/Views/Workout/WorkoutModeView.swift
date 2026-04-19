// WorkoutModeView.swift
// Vaux

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
                    totalSeconds: viewModel.currentPrescription?.restSeconds ?? 120,
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
                    if viewModel.isLoading {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Begin session")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
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
            .disabled(viewModel.isLoading)
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
                VStack(spacing: 12) {
                    // Compact coach feedback strip
                    if viewModel.isCoachThinking {
                        coachThinkingStrip
                    } else if let note = viewModel.coachNote {
                        CoachNoteStrip(note: note)
                    }

                    // Error display
                    if let error = viewModel.errorMessage {
                        errorStrip(error)
                    }

                    // Prescription card — the star
                    if viewModel.isLoading && viewModel.currentPrescription == nil {
                        prescriptionPlaceholder
                    } else if let rx = viewModel.currentPrescription {
                        PrescriptionCard(
                            prescription: rx,
                            exerciseSetIndex: viewModel.exerciseSetIndex,
                            loggedSets: viewModel.exerciseSetsForCurrentExercise,
                            currentPhase: viewModel.currentPhase,
                            phaseSetIndex: viewModel.phaseSetIndex
                        )
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                    }

                    // Set log input
                    SetLogInput(
                        weight: $viewModel.inputWeight,
                        reps: $viewModel.inputReps,
                        rpe: $viewModel.inputRPE,
                        onLog: {
                            Haptic.medium()
                            Task { await viewModel.logSet() }
                        },
                        isLoading: false,
                        phase: viewModel.currentPhase
                    )

                    // Logged sets progress
                    if !viewModel.exerciseSetsForCurrentExercise.isEmpty {
                        SetProgressRow(sets: viewModel.exerciseSetsForCurrentExercise)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

            InlineChatInput(
                text: $viewModel.inlineChatText,
                isExpanded: $viewModel.showInlineChat,
                onSend: { Task { await viewModel.sendInlineMessage() } },
                isLoading: viewModel.isCoachThinking
            )
        }
    }

    // MARK: - Coach feedback strips

    private var coachThinkingStrip: some View {
        HStack(spacing: 8) {
            CoachAvatar()
            Text("Coach is thinking…")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.textSecondary)
            Spacer()
            ProgressView()
                .scaleEffect(0.7)
                .tint(Color.accentTeal)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.surfaceRaised)
        )
    }

    private func errorStrip(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
            Text(message)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Color.recoveryRed)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.recoveryRed.opacity(0.1))
        )
    }

    private var prescriptionPlaceholder: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.surface)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.surface)
                        .frame(width: 120, height: 10)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.surface)
                        .frame(width: 180, height: 16)
                }
                Spacer()
            }
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.surface)
                .frame(height: 60)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.cardBackground)
        )
        .redacted(reason: .placeholder)
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

// MARK: - Coach note strip

struct CoachNoteStrip: View {
    let note: String
    @State private var expanded = false

    var body: some View {
        Button {
            withAnimation(Motion.smooth) { expanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                CoachAvatar()

                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(expanded ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.textTertiary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.cardBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
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
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
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
