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
    @State private var isSyncing = false
    @State private var syncError: String?

    var switchToChatTab: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.background.ignoresSafeArea()
                ambientGlow

                if viewModel.isLoading && viewModel.recovery == nil {
                    ProgressView()
                        .tint(.recoveryGreen)
                        .scaleEffect(1.2)
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
            VStack(alignment: .leading, spacing: 18) {
                header
                    .padding(.top, 8)

                RecoveryRing(
                    score: viewModel.recoveryScore,
                    level: viewModel.recoveryColor,
                    statusText: viewModel.hrvDeltaText,
                    sleep: viewModel.recovery?.sleepHours,
                    hrv: viewModel.recovery?.hrv,
                    rhr: viewModel.recovery?.restingHr
                )

                QuickActionsBar(
                    onWorkout: { navigateToWorkout = true },
                    onChat: { switchToChatTab?() },
                    onLogWeight: { showWeightSheet = true },
                    onSync: { Task { await performSync() } }
                )

                HRVSparkline(
                    history: viewModel.hrvHistory,
                    average: viewModel.hrvAvg
                )

                metricsGrid

                SessionTypeCard(mesocycle: viewModel.mesocycle) {
                    navigateToWorkout = true
                }

                if let err = syncError {
                    Text(err)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.recoveryRed)
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 18)
        }
        .refreshable { await viewModel.load() }
    }

    // MARK: - Header (greeting + streak pill)

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                Text("Dashboard")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Spacer()
            if viewModel.currentStreak > 0 {
                streakPill
            }
        }
    }

    private var streakPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "flame.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accentAmber)
            Text("\(viewModel.currentStreak)d streak")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.accentAmber.opacity(0.14))
        )
        .overlay(
            Capsule()
                .stroke(Color.accentAmber.opacity(0.28), lineWidth: 0.5)
        )
    }

    // MARK: - Metrics grid

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            MetricCard(
                icon: "moon.fill",
                title: "Sleep",
                value: sleepValue,
                subtitle: sleepSubtitle,
                accentColor: .accentBlue,
                sparkline: sleepSparkline
            )

            MetricCard(
                icon: "heart.fill",
                title: "Resting HR",
                value: rhrValue,
                subtitle: rhrSubtitle,
                trend: rhrTrend,
                trendColor: rhrTrendColor,
                accentColor: .recoveryRed,
                sparkline: rhrSparkline
            )

            if let weight = viewModel.recovery?.weightKg {
                MetricCard(
                    icon: "scalemass.fill",
                    title: "Weight",
                    value: weight.weightString,
                    subtitle: viewModel.recovery?.bodyFatPct.map { "\($0.oneDecimal)% body fat" },
                    accentColor: .accentAmber,
                    sparkline: weightSparkline
                )
            }

            if viewModel.weekTonnage > 0 {
                MetricCard(
                    icon: "flame.fill",
                    title: "7d Tonnage",
                    value: tonnageValue,
                    subtitle: "\(viewModel.recentSessions.count) sessions",
                    accentColor: .accentPurple
                )
            } else if let steps = viewModel.recovery?.steps {
                MetricCard(
                    icon: "figure.walk",
                    title: "Steps",
                    value: formatSteps(steps),
                    accentColor: .recoveryGreen
                )
            }
        }
    }

    // MARK: - Ambient glow

    private var ambientGlow: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(Color.accentPurple.opacity(0.12))
                    .frame(width: 280, height: 280)
                    .blur(radius: 90)
                    .offset(x: -geo.size.width * 0.35, y: -geo.size.height * 0.35)
                Circle()
                    .fill(Color.recoveryGreen.opacity(0.10))
                    .frame(width: 260, height: 260)
                    .blur(radius: 90)
                    .offset(x: geo.size.width * 0.4, y: geo.size.height * 0.1)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    // MARK: - Sync

    private func performSync() async {
        guard !isSyncing else { return }
        isSyncing = true
        syncError = nil
        do {
            try await HealthKitManager.shared.syncToSupabase()
            Haptic.success()
            await viewModel.load()
        } catch {
            Haptic.error()
            syncError = "Sync failed: \(error.localizedDescription)"
        }
        isSyncing = false
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
        return "\(hours.oneDecimal)h"
    }

    private var sleepSubtitle: String? {
        guard let hours = viewModel.recovery?.sleepHours else { return nil }
        if hours >= 7.5 { return "Good" }
        if hours >= 6.0 { return "Moderate" }
        return "Low"
    }

    private var rhrValue: String {
        guard let rhr = viewModel.recovery?.restingHr else { return "—" }
        return "\(Int(rhr))"
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

    private var rhrTrendColor: Color? {
        guard let trend = rhrTrend else { return nil }
        switch trend {
        case .down: return .recoveryGreen
        case .up: return .recoveryRed
        default: return nil
        }
    }

    private var tonnageValue: String {
        let kg = viewModel.weekTonnage
        if kg >= 1000 { return String(format: "%.1ft", kg / 1000) }
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
