// DashboardView.swift
// FitnessCoach

import SwiftUI

/// Main dashboard screen showing recovery status, HRV trend, key metrics,
/// and today's workout session type.
struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()
    @State private var navigateToWorkout = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.background.ignoresSafeArea()

                if viewModel.isLoading {
                    ProgressView()
                        .tint(.recoveryGreen)
                        .scaleEffect(1.2)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 16) {
                            // Recovery Ring
                            RecoveryRing(
                                score: viewModel.recoveryScore,
                                level: viewModel.recoveryColor,
                                statusText: recoveryStatusText
                            )
                            .padding(.top, 8)

                            // HRV Sparkline
                            HRVSparkline(
                                history: viewModel.hrvHistory,
                                average: viewModel.hrvAvg
                            )

                            // Metric cards row
                            HStack(spacing: 12) {
                                MetricCard(
                                    icon: "moon.fill",
                                    title: "Sleep",
                                    value: sleepValue,
                                    subtitle: sleepSubtitle,
                                    accentColor: .recoveryGreen
                                )

                                MetricCard(
                                    icon: "heart.fill",
                                    title: "Resting HR",
                                    value: rhrValue,
                                    subtitle: rhrSubtitle,
                                    trend: rhrTrend,
                                    accentColor: .recoveryRed
                                )
                            }

                            // Weight card
                            if let weight = viewModel.recovery?.weightKg {
                                MetricCard(
                                    icon: "scalemass.fill",
                                    title: "Weight",
                                    value: weight.weightString,
                                    subtitle: viewModel.recovery?.bodyFatPct.map { "\($0.oneDecimal)% body fat" }
                                )
                            }

                            // Session Type Card
                            SessionTypeCard(mesocycle: viewModel.mesocycle) {
                                navigateToWorkout = true
                            }

                            // Additional metrics
                            if let steps = viewModel.recovery?.steps {
                                MetricCard(
                                    icon: "figure.walk",
                                    title: "Steps",
                                    value: formatSteps(steps),
                                    accentColor: .recoveryGreen
                                )
                            }

                            Spacer(minLength: 20)
                        }
                        .padding(.horizontal)
                    }
                    .refreshable {
                        await viewModel.load()
                    }
                }
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $navigateToWorkout) {
                WorkoutModeView(sessionType: viewModel.mesocycle.todayType)
            }
            .task {
                await viewModel.load()
            }
        }
    }

    // MARK: - Computed Display Values

    private var recoveryStatusText: String {
        guard let hrv = viewModel.recovery?.hrv else { return "" }
        if let avg = viewModel.hrvAvg {
            let diff = hrv - avg
            let sign = diff >= 0 ? "+" : ""
            return "HRV \(Int(hrv)) ms (\(sign)\(Int(diff)) vs avg)"
        }
        return "HRV \(Int(hrv)) ms"
    }

    private var sleepValue: String {
        guard let hours = viewModel.recovery?.sleepHours else { return "--" }
        return "\(hours.oneDecimal)h"
    }

    private var sleepSubtitle: String? {
        guard let hours = viewModel.recovery?.sleepHours else { return nil }
        if hours >= 7.5 { return "Good" }
        if hours >= 6.0 { return "Moderate" }
        return "Low"
    }

    private var rhrValue: String {
        guard let rhr = viewModel.recovery?.restingHr else { return "--" }
        return "\(Int(rhr)) bpm"
    }

    private var rhrSubtitle: String? {
        guard let avg = viewModel.rhrAvg else { return nil }
        return "7d avg: \(Int(avg))"
    }

    private var rhrTrend: MetricCard.Trend? {
        guard let rhr = viewModel.recovery?.restingHr, let avg = viewModel.rhrAvg else { return nil }
        // For RHR, lower is better so invert the trend indicator
        if rhr < avg - 2 { return .down }
        if rhr > avg + 2 { return .up }
        return .flat
    }

    private func formatSteps(_ steps: Int) -> String {
        if steps >= 1000 {
            let k = Double(steps) / 1000.0
            return String(format: "%.1fk", k)
        }
        return "\(steps)"
    }
}

#Preview {
    DashboardView()
}
