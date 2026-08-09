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
    @AppStorage(Config.displayNameKey) private var displayName: String = ""

    var switchToChatTab: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                TechBackground(accent: .signal)

                // Three states, not two. A failed load with nothing cached
                // used to fall through to `content`, which rendered a
                // dashboard of em-dashes and zeroes — indistinguishable from a
                // genuinely empty account, and offering no way to try again.
                if viewModel.isLoading && viewModel.recovery == nil {
                    loadingState
                } else if let error = viewModel.errorMessage, viewModel.recovery == nil {
                    errorState(error)
                } else {
                    content
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $navigateToWorkout) {
                WorkoutModeView(sessionType: viewModel.mesocycle.todayType)
            }
            .sheet(isPresented: $showWeightSheet) {
                WeightLogSheet(initialWeight: viewModel.latestWeightKg) {
                    Task { await viewModel.load() }
                }
            }
            .task { await viewModel.load() }
            .onReceive(NotificationCenter.default.publisher(for: .mesocycleDidChange)) { _ in
                Task { await viewModel.refreshMesocycle() }
            }
        }
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(spacing: 18) {
            VauxLogo(size: 34, color: .signal)
                .shadow(color: Color.signal.opacity(0.5), radius: 16)
            HStack(spacing: 8) {
                GlowDot(color: .signal, size: 5)
                Text("SYNCING RECOVERY DATA")
                    .font(.eyebrowSmall)
                    .kerning(1.6)
                    .foregroundStyle(Color.fg2)
            }
        }
    }

    // MARK: - Error

    /// Shown when the load failed and there is nothing cached to fall back on.
    /// Names the underlying reason rather than "Something went wrong" — the
    /// difference between being offline, a bad backend URL, and an expired key
    /// is the whole of what the reader needs to act, and it is the difference
    /// the message already carries.
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            IconBadge(systemName: "wifi.exclamationmark", accent: .ember, size: 72)

            VStack(spacing: 8) {
                Text("Couldn't load your data")
                    .font(.serifMD)
                    .foregroundStyle(Color.fg0)

                Text(message)
                    .font(.uiSmall)
                    .foregroundStyle(Color.fg2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)

            Button {
                Haptic.light()
                Task { await viewModel.load() }
            } label: {
                CTALabel(
                    text: "Try again",
                    icon: "arrow.clockwise",
                    busy: viewModel.isLoading
                )
            }
            .buttonStyle(PressScaleStyle())
            .disabled(viewModel.isLoading)
            .padding(.top, 4)

            Spacer()
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .contain)
    }

    /// Non-blocking variant, for a refresh that failed while earlier data is
    /// still on screen. Stale numbers beat no numbers, so the banner sits above
    /// them rather than replacing them.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Showing your last synced data")
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.uiSmall)
                    .foregroundStyle(Color.ember.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.ember)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ember.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.ember.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                header
                    .padding(.top, 4)
                    .riseIn()

                // Reaching `content` with an error set means the load failed
                // but earlier data survived, so this is a caveat on what's
                // below rather than a replacement for it.
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                        .riseIn(delay: 0.03)
                }

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
                .riseIn(delay: 0.06)

                SessionTypeCard(mesocycle: viewModel.mesocycle) {
                    navigateToWorkout = true
                }
                .riseIn(delay: 0.12)

                metricsGrid
                    .riseIn(delay: 0.18)

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

    // MARK: - Header — editorial masthead

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    VauxLogo(size: 16, color: .fg1)
                    Text("VAUX")
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(3)
                        .foregroundStyle(Color.fg1)
                }
                Spacer()
                if viewModel.currentStreak > 0 {
                    streakPill
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(greeting)
                    .font(.serifLG)
                    .foregroundStyle(Color.fg0)

                HStack(spacing: 8) {
                    GlowDot(color: .signal, size: 4)
                    Eyebrow(text: formattedDate)
                    Eyebrow(text: "·", color: .fg3)
                    Eyebrow(text: "Week \(viewModel.mesocycle.week) Day \(viewModel.mesocycle.day)")
                }
            }
        }
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE · MMM d"
        return f.string(from: Date())
    }

    private var streakPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.amber)
            Text("\(viewModel.currentStreak)D STREAK")
                .font(.eyebrowSmall)
                .kerning(1.2)
                .foregroundStyle(Color.amber)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.amber.opacity(0.08)))
        .overlay(
            Capsule()
                .stroke(Color.amber.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: - Metrics grid (This week)

    private var metricsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "This week")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                MetricCard(
                    icon: "moon.fill",
                    title: "Sleep",
                    value: sleepValue,
                    subtitle: sleepSubtitle,
                    accentColor: .iris,
                    sparkline: sleepSparkline
                )

                MetricCard(
                    icon: "heart.fill",
                    title: "Resting HR",
                    value: rhrValue,
                    subtitle: rhrSubtitle,
                    trend: rhrTrend,
                    trendColor: rhrTrendColor,
                    accentColor: .ember,
                    sparkline: rhrSparkline
                )

                Button {
                    Haptic.light()
                    showWeightSheet = true
                } label: {
                    if let weight = viewModel.latestWeightKg {
                        MetricCard(
                            icon: "scalemass.fill",
                            title: "Weight",
                            value: "\(weight.oneDecimal) kg",
                            subtitle: viewModel.latestBodyFatPct.map { "\($0.oneDecimal)% body fat" } ?? "Tap to log",
                            accentColor: .amber,
                            sparkline: weightSparkline,
                            isTappable: true
                        )
                    } else {
                        MetricCard(
                            icon: "scalemass.fill",
                            title: "Weight",
                            value: "—",
                            subtitle: "Tap to log",
                            accentColor: .amber,
                            isTappable: true
                        )
                    }
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityHint("Opens the weight log")

                if viewModel.weekTonnage > 0 {
                    MetricCard(
                        icon: "flame.fill",
                        title: "Tonnage",
                        value: tonnageValue,
                        subtitle: "\(viewModel.recentSessions.count) sessions",
                        accentColor: .signal
                    )
                } else if let steps = viewModel.recovery?.steps {
                    MetricCard(
                        icon: "figure.walk",
                        title: "Steps",
                        value: formatSteps(steps),
                        accentColor: .mint
                    )
                }
            }
        }
    }

    // MARK: - Computed display values

    /// Time-of-day greeting, with the athlete's name when one is set. The name
    /// was hardcoded to a single person; it now comes from Settings, and an
    /// empty value simply yields the greeting on its own rather than a dangling
    /// comma.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let salutation: String
        switch hour {
        case 5..<12: salutation = "Good morning"
        case 12..<17: salutation = "Good afternoon"
        case 17..<22: salutation = "Good evening"
        default: salutation = "Welcome back"
        }

        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? salutation : "\(salutation), \(name)"
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
