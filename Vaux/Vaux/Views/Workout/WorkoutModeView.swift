import SwiftUI

struct WorkoutModeView: View {
    @State private var viewModel = WorkoutViewModel()
    var sessionType: String = ""

    var body: some View {
        NavigationStack {
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
                        onSkip: { viewModel.isResting = false }
                    )
                }

                if viewModel.showPRCelebration, let pr = viewModel.latestPR {
                    PRCelebration(
                        exercise: pr.exercise,
                        estimated1RM: pr.estimated1RM,
                        isShowing: $viewModel.showPRCelebration
                    )
                }
            }
            .navigationTitle(viewModel.isActive ? viewModel.sessionType : "Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.isActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("End") {
                            Task { await viewModel.endWorkout() }
                        }
                        .foregroundColor(Color.recoveryRed)
                    }
                }
            }
            .sheet(isPresented: $viewModel.showSummary) {
                if let summary = viewModel.summary {
                    WorkoutSummaryView(summary: summary) {
                        viewModel.showSummary = false
                        viewModel.isActive = false
                    }
                }
            }
        }
    }

    private var startView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 64))
                .foregroundColor(Color.recoveryGreen)

            Text(sessionType.isEmpty ? "Ready to train?" : "\(sessionType) Day")
                .font(.title.weight(.bold))
                .foregroundColor(.white)

            Button {
                Task { await viewModel.startWorkout(type: sessionType) }
            } label: {
                Text("Start Workout")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.recoveryGreen)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 40)
            Spacer()
        }
    }

    private var activeWorkoutView: some View {
        VStack(spacing: 0) {
            LiveStatsBar(
                tonnage: viewModel.totalTonnage,
                setCount: viewModel.setCount,
                duration: viewModel.sessionDuration
            )

            ScrollView {
                VStack(spacing: 16) {
                    ForEach(viewModel.coachMessages, id: \.content) { msg in
                        if !msg.isUser {
                            MessageBubble(message: msg)
                        }
                    }

                    if let rx = viewModel.currentPrescription {
                        PrescriptionCard(prescription: rx)
                    }

                    SetLogInput(
                        weight: $viewModel.inputWeight,
                        reps: $viewModel.inputReps,
                        rpe: $viewModel.inputRPE,
                        onLog: { Task { await viewModel.logSet() } },
                        isLoading: viewModel.isLoading
                    )
                }
                .padding()
            }

            InlineChatInput(
                text: $viewModel.inlineChatText,
                isExpanded: $viewModel.showInlineChat,
                onSend: { Task { await viewModel.sendInlineMessage() } },
                isLoading: viewModel.isLoading
            )
        }
    }
}
