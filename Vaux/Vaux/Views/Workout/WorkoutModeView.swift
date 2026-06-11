// WorkoutModeView.swift
// Vaux

import SwiftUI

struct WorkoutModeView: View {
    @State private var viewModel = WorkoutViewModel()
    @State private var resolvedSessionType: String = ""
    @State private var didResolveType = false
    /// Set to false while the view is probing Supabase for an in-progress
    /// session on appearance. Shown as a brief loading state so an
    /// accidental back-swipe doesn't flash the "Begin session" screen
    /// before the resume kicks in — that flash made it look like the
    /// workout had been thrown away when it was still on disk.
    @State private var didCheckResume = false

    /// Session type passed explicitly (e.g. from the Dashboard CTA). When left
    /// empty — the Train tab mounts this view with no argument — the view
    /// resolves today's type from `MesocycleService` so the tab matches the
    /// Dashboard instead of showing an empty "Full body" placeholder.
    var sessionType: String = ""

    private var effectiveSessionType: String {
        sessionType.isEmpty ? resolvedSessionType : sessionType
    }

    private var isNonStrengthDay: Bool {
        effectiveSessionType == "Cardio+Abs" || effectiveSessionType == "Yoga"
    }

    var body: some View {
        ZStack {
            TechBackground(accent: Color.forSession(effectiveSessionType.isEmpty ? "Session" : effectiveSessionType))

            if isNonStrengthDay && !viewModel.isActive && !viewModel.showSummary {
                CardioYogaLogView(
                    sessionType: effectiveSessionType,
                    onStartStrengthSession: effectiveSessionType == "Cardio+Abs"
                        ? { Task { await viewModel.startOrResumeWorkout(type: effectiveSessionType) } }
                        : nil
                )
            } else if !viewModel.isActive && !viewModel.showSummary {
                if didCheckResume {
                    startView
                } else {
                    resumeCheckView
                }
            } else {
                activeWorkoutView
            }

            if viewModel.isResting {
                RestTimer(
                    totalSeconds: viewModel.currentPrescription?.restSeconds ?? 120,
                    endDate: $viewModel.restEndDate,
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
        .task {
            // Only fall back to the mesocycle service when the caller didn't
            // already hand us a session type. Loads once per view lifetime.
            if sessionType.isEmpty, !didResolveType {
                didResolveType = true
                if let state = try? await MesocycleService().loadState() {
                    resolvedSessionType = state.todayType
                }
            }
            // If the user left mid-workout (accidental back-swipe, app
            // backgrounded, etc.) the Supabase session is still `in_progress`
            // — pick it back up automatically instead of showing the start
            // screen, which would otherwise mint a brand-new session on tap.
            if !isNonStrengthDay {
                await viewModel.resumeIfInProgress(type: effectiveSessionType)
            }
            didCheckResume = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .mesocycleDidChange)) { _ in
            // Settings (or post-workout advance) changed today's session.
            // Only re-resolve when this view is showing today's auto-picked
            // type — if the Dashboard navigated in with an explicit
            // `sessionType`, that's the workout the user committed to and
            // we shouldn't swap it out mid-flow.
            guard sessionType.isEmpty, !viewModel.isActive else { return }
            Task {
                if let state = try? await MesocycleService().loadState() {
                    resolvedSessionType = state.todayType
                }
            }
        }
        .navigationTitle(viewModel.isActive ? viewModel.sessionType : (effectiveSessionType.isEmpty ? "Workout" : effectiveSessionType))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.isActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptic.warning()
                        Task { await viewModel.endWorkout() }
                    } label: {
                        Text("END")
                            .font(.eyebrowSmall)
                            .kerning(1.2)
                            .foregroundStyle(Color.ember)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.ember.opacity(0.08)))
                            .overlay(Capsule().stroke(Color.ember.opacity(0.22), lineWidth: 1))
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
        // Block the swipe-from-edge back gesture while a workout is in
        // progress (or while we're probing for one to resume). The view
        // will auto-resume after an accidental dismissal, but the flash
        // of the start screen looked like the session had been thrown
        // away — disabling the gesture avoids the surprise entirely.
        // Idle state (no active session, resume probe finished) keeps
        // the back-swipe so the Begin screen still feels like a normal
        // push.
        .interactivePopGesture(enabled: !viewModel.isActive && didCheckResume)
    }

    // MARK: - Resume probe

    /// Shown for the brief moment between the view appearing and
    /// `resumeIfInProgress` returning. Prevents the "Begin session" screen
    /// from flashing into view when the user is actually re-entering a
    /// workout that's still in progress on the server.
    private var resumeCheckView: some View {
        VStack(spacing: 18) {
            Spacer()
            VauxLogo(size: 30, color: .signal)
                .shadow(color: Color.signal.opacity(0.5), radius: 14)
            HStack(spacing: 8) {
                GlowDot(color: .signal, size: 5)
                Text("SYNCING SESSION STATE")
                    .font(.eyebrowSmall)
                    .kerning(1.6)
                    .foregroundStyle(Color.fg2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Start screen — session brief

    private var startView: some View {
        let type = effectiveSessionType.isEmpty ? "Session" : effectiveSessionType
        let accent = Color.forSession(type)
        return VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(accent.opacity(0.10), lineWidth: 1)
                    .frame(width: 156, height: 156)
                Circle()
                    .stroke(accent.opacity(0.22), lineWidth: 1)
                    .frame(width: 120, height: 120)
                Circle()
                    .fill(accent.opacity(0.08))
                    .frame(width: 120, height: 120)
                Image(systemName: iconForType(type))
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(accent)
                    .shadow(color: accent.opacity(0.6), radius: 12)
            }
            .padding(.bottom, 28)

            VStack(spacing: 10) {
                Eyebrow(text: "Session brief")

                Text(effectiveSessionType.isEmpty ? "Start workout" : "\(effectiveSessionType) Day")
                    .font(.serifLG)
                    .foregroundStyle(Color.fg0)

                Text(focusForType(type).uppercased())
                    .font(.eyebrowSmall)
                    .kerning(1.6)
                    .foregroundStyle(Color.fg2)
                    .padding(.top, 2)
            }

            briefStrip(accent: accent)
                .padding(.horizontal, 24)
                .padding(.top, 28)

            Spacer()

            Button {
                Haptic.medium()
                Task { await viewModel.startOrResumeWorkout(type: effectiveSessionType) }
            } label: {
                CTALabel(
                    text: "Begin session",
                    icon: "play.fill",
                    busy: viewModel.isLoading
                )
            }
            .buttonStyle(PressScaleStyle())
            .disabled(viewModel.isLoading)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    /// Mono data strip under the session title: coach mode, live tracking,
    /// and progression — quiet reassurance that the system is armed.
    private func briefStrip(accent: Color) -> some View {
        HStack(spacing: 0) {
            briefCell(label: "Coach", value: "ARMED")
            Rectangle().fill(Color.line).frame(width: 1, height: 30)
            briefCell(label: "Tracking", value: "LIVE")
            Rectangle().fill(Color.line).frame(width: 1, height: 30)
            briefCell(label: "Plan", value: "ADAPTIVE")
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.ink1.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
    }

    private func briefCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.eyebrowSmall)
                .kerning(1.2)
                .foregroundStyle(Color.fg3)
            Text(value)
                .font(.eyebrow)
                .kerning(1.2)
                .foregroundStyle(Color.fg0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Active workout

    private var activeWorkoutView: some View {
        VStack(spacing: 0) {
            LiveStatsBar(
                tonnage: viewModel.totalTonnage,
                setCount: viewModel.setCount,
                duration: viewModel.sessionDuration,
                heartRate: viewModel.heartRateMonitor.currentBPM
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

                        if viewModel.upcomingPrescriptions.count > 0 {
                            UpcomingExercisesCard(names: viewModel.upcomingPrescriptions.map(\.exerciseName))
                        }
                    } else {
                        emptyPrescriptionCard
                    }

                    // Set log input — only meaningful when we actually
                    // have a prescription to log against. If a network
                    // error left `currentPrescription` nil on resume, the
                    // input form rendered below the "No plan yet" card
                    // anyway, offering "Log warm-up: 0kg × 8" with no
                    // target. Suppress it until the coach replies again.
                    if viewModel.currentPrescription != nil {
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
                    }

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
                .font(.uiSmall)
                .foregroundStyle(Color.fg1)
            Spacer()
            ProgressView()
                .scaleEffect(0.7)
                .tint(Color.signal)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.ink3)
        )
    }

    private func errorStrip(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
            Text(message)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Color.ember)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ember.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.ember.opacity(0.22), lineWidth: 1)
        )
    }

    private var emptyPrescriptionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "No plan yet")
            Text("The coach didn't send exercises for this session.")
                .font(.uiStrong)
                .foregroundStyle(Color.fg0)
            Text("Tap retry to ask again, or end the session and start a new one.")
                .font(.uiSmall)
                .foregroundStyle(Color.fg1)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Haptic.light()
                Task { await viewModel.retryPrescription() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Retry")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.fg0)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.ink3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.line2, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLoading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.cardBorder, lineWidth: 0.5)
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
                    .foregroundStyle(Color.fg0.opacity(0.9))
                    .lineLimit(expanded ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.fg2)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.ink3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.line, lineWidth: 1)
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
                Eyebrow(text: "Logged")
                Spacer()
                Text("\(sets.count) set\(sets.count == 1 ? "" : "s")".uppercased())
                    .font(.eyebrowSmall)
                    .kerning(1.0)
                    .foregroundStyle(Color.fg2)
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
        // Bodyweight prescriptions log a 0 weight — render "BW" instead of
        // "0×N" so a logged pull-up reads as "BW × 5", not a zero lift.
        let weightLabel = weight > 0 ? "\(Int(weight))" : "BW"
        return VStack(spacing: 3) {
            Text("SET \(index)")
                .font(.eyebrowSmall)
                .foregroundStyle(Color.fg2)
            Text("\(weightLabel)×\(reps)")
                .font(.system(size: 13, weight: .medium, design: .monospaced).monospacedDigit())
                .foregroundStyle(Color.fg0)
            if let rpe {
                Text("RPE \(rpe.oneDecimal)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.mint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ink3)
        )
    }
}

// MARK: - Upcoming exercises

struct UpcomingExercisesCard: View {
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(text: "Up next")
                Spacer()
                Text("\(names.count)")
                    .font(.eyebrowSmall)
                    .foregroundStyle(Color.fg2)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(names.enumerated()), id: \.offset) { idx, name in
                    HStack(spacing: 10) {
                        Text("\(idx + 2).")
                            .font(.system(size: 12, weight: .medium, design: .monospaced).monospacedDigit())
                            .foregroundStyle(Color.fg2)
                            .frame(width: 22, alignment: .leading)
                        Text(name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.fg1)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.cardBorder, lineWidth: 0.5)
        )
    }
}
