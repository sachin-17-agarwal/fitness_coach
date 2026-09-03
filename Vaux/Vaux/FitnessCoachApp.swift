// FitnessCoachApp.swift
// Vaux — editorial redesign
//
// Info.plist entries required:
//   NSHealthShareUsageDescription - "Vaux reads your health data (HRV, heart rate, sleep, steps, VO2 max) to provide personalised recovery and training insights."
//   NSHealthUpdateUsageDescription - "Vaux writes workout data to Apple Health so your training history stays in sync."

import SwiftUI
import HealthKit

@main
struct FitnessCoachApp: App {
    @State private var selectedTab: Tab = .home

    init() {
        configureNavBarAppearance()
        // Must be installed before any rest alert could be delivered, so that
        // one arriving while the app is frontmost is suppressed in favour of
        // the on-screen countdown.
        RestNotifier.shared.start()
        // If the app was killed mid-rest, iOS still has the Live Activity on
        // the Lock Screen — nothing told it the workout ended. Clear it here
        // so today's session doesn't open underneath yesterday's countdown.
        Task { @MainActor in RestActivityController.shared.clearOrphans() }
        requestHealthKitAuthorization()
        Task { await WorkoutService().cleanupStaleSessions() }
    }

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottom) {
                Color.ink0.ignoresSafeArea()

                tabContent
                    // Reserve room at the bottom so content never sits
                    // underneath the tab bar.
                    .padding(.bottom, CapsuleTabBar.reservedHeight)

                CapsuleTabBar(selected: $selectedTab)
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Tab content

    // Every tab stays mounted so scroll position and in-flight state survive
    // switching, which is why this is opacity rather than a real TabView.
    //
    // The catch is that neither `opacity(0)` nor `allowsHitTesting(false)`
    // removes a view from the accessibility tree — so VoiceOver used to walk
    // straight out of the Dashboard and into the Coach screen, then the
    // workout screen, with nothing announcing the crossing. `accessibilityHidden`
    // is the modifier that actually withdraws them, and it has to track the
    // selection exactly like the other two do.
    @ViewBuilder
    private var tabContent: some View {
        ZStack {
            DashboardView(switchToChatTab: { selectedTab = .coach })
                .hiddenUnlessActive(selectedTab == .home)

            CoachChatView(switchToTrainTab: { selectedTab = .train })
                .hiddenUnlessActive(selectedTab == .coach)

            NavigationStack {
                WorkoutModeView()
            }
            .hiddenUnlessActive(selectedTab == .train)

            HistoryView(switchToChatTab: { selectedTab = .coach })
                .hiddenUnlessActive(selectedTab == .history)

            SettingsView()
                .hiddenUnlessActive(selectedTab == .settings)
        }
    }

    // MARK: - Tab enum

    enum Tab: Hashable, CaseIterable {
        case home, coach, train, history, settings

        var title: String {
            switch self {
            case .home:     return "Home"
            case .coach:    return "Coach"
            case .train:    return "Train"
            case .history:  return "History"
            case .settings: return "Settings"
            }
        }

        var icon: String {
            switch self {
            case .home:     return "square.grid.2x2"
            case .coach:    return "sparkles"
            case .train:    return "figure.strengthtraining.traditional"
            case .history:  return "chart.xyaxis.line"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    // MARK: - Appearance

    private func configureNavBarAppearance() {
        // Glass chrome: dark blur + ink tint with a hairline shadow, so
        // pushed screens match the floating tab bar instead of showing a
        // flat opaque strip over the dot-grid background.
        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        navBarAppearance.backgroundColor = UIColor(Color.ink0).withAlphaComponent(0.72)
        navBarAppearance.shadowColor = UIColor(Color.line)
        navBarAppearance.titleTextAttributes = [
            .foregroundColor: UIColor(Color.fg0),
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold)
        ]
        navBarAppearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor(Color.fg0),
            .font: UIFont.systemFont(ofSize: 30, weight: .bold)
        ]
        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
        UINavigationBar.appearance().compactAppearance = navBarAppearance
    }

    // MARK: - HealthKit

    private func requestHealthKitAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        Task {
            do {
                try await HealthKitManager.shared.requestAuthorization()
                HealthKitManager.shared.enableBackgroundSync()
                // Always revisit the last week on launch. Today's row is what
                // the dashboard needs immediately, but re-syncing the prior
                // days lets the new day-scoped body-composition logic clear
                // stale values that earlier (unscoped) syncs stamped onto
                // days with no actual weigh-in.
                try await HealthKitManager.shared.syncRecent(days: 7)
            } catch {
                print("[HealthKit] Startup sync failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Tab visibility

private extension View {
    /// Hides a mounted-but-unselected tab from sight, touch, and assistive
    /// technology together, so the three can't drift out of step.
    func hiddenUnlessActive(_ isActive: Bool) -> some View {
        opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}

// MARK: - Tab bar
//
// Flat bar on the ink ground with a hairline top edge: outline icon and an
// eyebrow label per tab, the active one in signal lime. No pill, no blur —
// the same bar that sits under every screen in the scheme.

struct CapsuleTabBar: View {
    @Binding var selected: FitnessCoachApp.Tab

    /// Height the bar occupies above the home indicator — used by the app
    /// root to leave room below scrolling content.
    static let reservedHeight: CGFloat = 62

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FitnessCoachApp.Tab.allCases, id: \.self) { tab in
                tabItem(tab)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .frame(maxWidth: .infinity)
        .frame(height: Self.reservedHeight, alignment: .top)
        .background(
            Color.ink0
                .overlay(Rectangle().fill(Color.line).frame(height: 1), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func tabItem(_ tab: FitnessCoachApp.Tab) -> some View {
        let isSelected = selected == tab
        return Button {
            guard selected != tab else { return }
            Haptic.light()
            withAnimation(Motion.snappy) { selected = tab }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isSelected ? Color.signal : Color.fg2)
                    .frame(height: 20)

                // fg2 (~5.7:1 on ink0) for the inactive label — fg3 sits
                // under 4.5:1 at this size. The active tab is lime, the one
                // colour on the bar.
                Text(tab.title.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .kerning(1.5)
                    .foregroundStyle(isSelected ? Color.signal : Color.fg2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The lime fill and glow are the only thing marking the current tab;
        // `.isSelected` is how that reaches VoiceOver, which would otherwise
        // announce all five identically and give no way to tell where you are.
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
