// DashboardView.swift
// Vaux
//
// Main recovery + training dashboard. Composes the hero recovery ring,
// quick actions, HRV sparkline, metric grid, and today's session card.

import SwiftUI

struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()
    @State private var navigateToWorkout = false
    @State private var showWeightSheet = false
    @State private var syncError: String?

    var switchToChatTab: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.ink0.ignoresSafeArea()

                if viewModel.isLoading && viewModel.recovery == nil {
                    ProgressView()
                        .tint(.signal)
                        .scaleEffect(1.0)
                } else {
                    content
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $navigateToWorkout) {
                WorkoutModeView(sessionType: viewModel.mesocycle.todayType)
            }
            .sheet(isPresented: $showWeightSheet) {
                WeightLogSheet(initialWeight: viewModel.recovery?.weightKg) {
                    Task { await viewModel.load() }
                }
            }
            .task { await viewModel.load() }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                header
                    .padding(.top, 4)

                RecoveryRing(
                    score: viewModel.recoveryScore,
                    level: viewModel.recoveryColor,
                    statusText: viewModel.hrvDeltaText,
                    sleep: viewModel.recovery?.sleepHours,
                    hrv: viewModel.recovery?.hrv,
                    rhr: viewModel.recovery?.restingHr,
                    hrvDelta: hrvDeltaInt,
                    rhrDelta: rhrDeltaInt,
                    recentScores: recentRecoveryScores
                )

                SessionTypeCard(mesocycle: viewModel.mesocycle) {
                    navigateToWorkout = true
                }

                metricsGrid

                if let err = syncError {
                    Text(err)
                        .font(.uiSmall)
                        .foregroundStyle(Color.ember)
                }

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 22)
        }
        .refreshable { await viewModel.load() }
    }

    private var hrvDeltaInt: Int? {
        guard let hrv = viewModel.recovery?.hrv, let avg = viewModel.hrvAvg else { return nil }
        return Int((hrv - avg).rounded())
    }

    private var rhrDeltaInt: Int? {
        guard let rhr = viewModel.recovery?.restingHr, let avg = viewModel.rhrAvg else { return nil }
        return Int((rhr - avg).rounded())
    }

    private var recentRecoveryScores: [Int] {
        // Recompute each day's score relative to the rolling HRV average.
        guard let avg = viewModel.hrvAvg, avg > 0 else { return [] }
        return viewModel.recoveryHistory
            .reversed()
            .prefix(14)
            .map { rec -> Int in
                guard let hrv = rec.hrv else { return 0 }
                let ratio = hrv / avg
                return min(100, max(0, Int(ratio * 100)))
            }
            .reversed()
    }

    // MARK: - Header — editorial (wordmark left, streak chip right)

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                VauxLogo(size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: formattedDate)
                    Text("\(greeting), Sachin")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.fg0)
                }
            }
            Spacer()
            if viewModel.currentStreak > 0 {
                streakPill
            }
        }
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEE · MMM d"
        return f.string(from: Date())
    }

    private var streakPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "flame")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.amber)
            Text("\(viewModel.currentStreak)D STREAK")
                .font(.eyebrowSmall)
                .kerning(1.2)
                .foregroundStyle(Color.amber)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay(
            Capsule()
                .stroke(Color.amber.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Metrics grid (This week)

    private var metricsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "This week")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                MetricCard(
                    icon: "moon",
                    title: "Sleep",
                    value: sleepValue,
                    subtitle: sleepSubtitle,
                    sparkline: sleepSparkline
                )

                MetricCard(
                    icon: "heart",
                    title: "Resting HR",
                    value: rhrValue,
                    subtitle: rhrSubtitle,
                    trend: rhrTrend,
                    trendColor: rhrTrendColor,
                    sparkline: rhrSparkline
                )

                if let weight = viewModel.recovery?.weightKg {
                    MetricCard(
                        icon: "scalemass",
                        title: "Weight",
                        value: "\(weight.oneDecimal) kg",
                        subtitle: viewModel.recovery?.bodyFatPct.map { "\($0.oneDecimal)% body fat" },
                        sparkline: weightSparkline
                    )
                }

                if viewModel.weekTonnage > 0 {
                    MetricCard(
                        icon: "flame",
                        title: "Tonnage",
                        value: tonnageValue,
                        subtitle: "\(viewModel.recentSessions.count) sessions"
                    )
                } else if let steps = viewModel.recovery?.steps {
                    MetricCard(
                        icon: "figure.walk",
                        title: "Steps",
                        value: formatSteps(steps)
                    )
                }
            }
        }
    }

    // MARK: - Computed display values

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Welcome back"
        }
    }

    private var sleepValue: String {
        guard let hours = viewModel.recovery?.sleepHours else { return "—" }
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        return String(format: "%d:%02d hrs", h, m)
    }

    private var sleepSubtitle: String? {
        guard let hours = viewModel.recovery?.sleepHours else { return nil }
        if hours >= 7.5 { return "Good" }
        if hours >= 6.0 { return "Moderate" }
        return "Low"
    }

    private var rhrValue: String {
        guard let rhr = viewModel.recovery?.restingHr else { return "—" }
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

    // For RHR, lower is better — flip the default trend colors.
    private var rhrTrendColor: Color? {
        guard let trend = rhrTrend else { return nil }
        switch trend {
        case .down: return .mint
        case .up: return .ember
        default: return nil
        }
    }

    private var tonnageValue: String {
        let kg = viewModel.weekTonnage
        if kg >= 1000 { return String(format: "%.1f t", kg / 1000) }
        return "\(Int(kg)) kg"
    }

    private var sleepSparkline: [Double]? {
        let values = viewModel.recoveryHistory
            .reversed()
            .compactMap(\.sleepHours)
            .suffix(7)
        return values.count >= 2 ? Array(values) : nil
    }

    private var rhrSparkline: [Double]? {
        let values = viewModel.recoveryHistory
            .reversed()
            .compactMap(\.restingHr)
            .suffix(7)
        return values.count >= 2 ? Array(values) : nil
    }

    private var weightSparkline: [Double]? {
        let values = viewModel.recoveryHistory
            .reversed()
            .compactMap(\.weightKg)
            .suffix(7)
        return values.count >= 2 ? Array(values) : nil
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
