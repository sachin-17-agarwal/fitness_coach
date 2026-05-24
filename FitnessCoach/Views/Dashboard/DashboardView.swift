import SwiftUI

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
                        VStack(spacing: 20) {
                            recoveryHeroCard
                                .staggeredAppearance(index: 0)

                            SessionTypeCard(mesocycle: viewModel.mesocycle) {
                                navigateToWorkout = true
                            }
                            .staggeredAppearance(index: 1)

                            sectionHeader("THIS WEEK")
                                .staggeredAppearance(index: 2)

                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)
                            ], spacing: 12) {
                                MetricCard(
                                    icon: "moon.fill",
                                    title: "SLEEP",
                                    value: sleepValue,
                                    subtitle: sleepSubtitle,
                                    accentColor: Color(hex: "6B9DFF")
                                )
                                .staggeredAppearance(index: 3)

                                MetricCard(
                                    icon: "heart.fill",
                                    title: "RESTING HR",
                                    value: rhrValue,
                                    subtitle: rhrSubtitle,
                                    trend: rhrTrend,
                                    accentColor: .recoveryRed
                                )
                                .staggeredAppearance(index: 4)

                                if let weight = viewModel.recovery?.weightKg {
                                    MetricCard(
                                        icon: "scalemass.fill",
                                        title: "WEIGHT",
                                        value: weight.weightString,
                                        subtitle: viewModel.recovery?.bodyFatPct.map { "\($0.oneDecimal)% body fat" },
                                        accentColor: .recoveryYellow
                                    )
                                    .staggeredAppearance(index: 5)
                                }

                                if let steps = viewModel.recovery?.steps {
                                    MetricCard(
                                        icon: "figure.walk",
                                        title: "STEPS",
                                        value: formatSteps(steps),
                                        accentColor: .recoveryGreen
                                    )
                                    .staggeredAppearance(index: 6)
                                }
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
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $navigateToWorkout) {
                WorkoutModeView(sessionType: viewModel.mesocycle.todayType)
            }
            .task {
                await viewModel.load()
            }
        }
    }

    // MARK: - Recovery Hero Card

    private var recoveryHeroCard: some View {
        VStack(spacing: 16) {
            HStack {
                Text("RECOVERY")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Color.textSecondary)

                Spacer()

                Text(statusLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(recoveryLevelColor.opacity(0.15))
                    .foregroundStyle(recoveryLevelColor)
                    .clipShape(Capsule())
            }

            HStack(spacing: 20) {
                RecoveryRing(
                    score: viewModel.recoveryScore,
                    level: viewModel.recoveryColor
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(viewModel.recoveryScore)")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("%")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.textSecondary)
                    }

                    if !recoveryStatusText.isEmpty {
                        Text(recoveryStatusText)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(2)
                    }

                    Text(recoveryAdvice)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(recoveryLevelColor)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().background(Color.cardBorder)

            HStack(spacing: 0) {
                heroMetric(
                    label: "HRV",
                    value: viewModel.recovery?.hrv.map { "\(Int($0))" } ?? "--",
                    unit: "ms",
                    trend: hrvTrendIcon
                )

                Divider().frame(height: 36).background(Color.cardBorder)

                heroMetric(
                    label: "SLEEP",
                    value: sleepValue,
                    unit: "",
                    trend: nil
                )

                Divider().frame(height: 36).background(Color.cardBorder)

                heroMetric(
                    label: "RHR",
                    value: viewModel.recovery?.restingHr.map { "\(Int($0))" } ?? "--",
                    unit: "bpm",
                    trend: rhrTrendIcon
                )
            }
        }
        .darkCard()
    }

    private func heroMetric(label: String, value: String, unit: String, trend: (String, Color)?) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Color.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if let trend {
                    Image(systemName: trend.0)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(trend.1)
                }
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Computed Values

    private var recoveryLevelColor: Color {
        switch viewModel.recoveryColor {
        case .green: return .recoveryGreen
        case .yellow: return .recoveryYellow
        case .red: return .recoveryRed
        case .unknown: return .textSecondary
        }
    }

    private var statusLabel: String {
        switch viewModel.recoveryColor {
        case .green: return "Recovered"
        case .yellow: return "Moderate"
        case .red: return "Low"
        case .unknown: return "No Data"
        }
    }

    private var recoveryAdvice: String {
        switch viewModel.recoveryColor {
        case .green: return "Push hard today."
        case .yellow: return "Keep intensity moderate."
        case .red: return "Consider active recovery."
        case .unknown: return ""
        }
    }

    private var recoveryStatusText: String {
        guard let hrv = viewModel.recovery?.hrv else { return "" }
        if let avg = viewModel.hrvAvg {
            let diff = hrv - avg
            let sign = diff >= 0 ? "+" : ""
            return "HRV \(sign)\(Int(diff))ms vs baseline"
        }
        return "HRV \(Int(hrv)) ms"
    }

    private var hrvTrendIcon: (String, Color)? {
        guard let hrv = viewModel.recovery?.hrv, let avg = viewModel.hrvAvg else { return nil }
        if hrv >= avg { return ("arrow.up", .recoveryGreen) }
        return ("arrow.down", .recoveryRed)
    }

    private var sleepValue: String {
        guard let hours = viewModel.recovery?.sleepHours else { return "--" }
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        return "\(h):\(String(format: "%02d", m))"
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
        return "7d avg \(Int(avg)) bpm"
    }

    private var rhrTrend: MetricCard.Trend? {
        guard let rhr = viewModel.recovery?.restingHr, let avg = viewModel.rhrAvg else { return nil }
        if rhr < avg - 2 { return .down }
        if rhr > avg + 2 { return .up }
        return .flat
    }

    private var rhrTrendIcon: (String, Color)? {
        guard let rhr = viewModel.recovery?.restingHr, let avg = viewModel.rhrAvg else { return nil }
        if rhr < avg - 2 { return ("arrow.down", .recoveryGreen) }
        if rhr > avg + 2 { return ("arrow.up", .recoveryRed) }
        return nil
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
