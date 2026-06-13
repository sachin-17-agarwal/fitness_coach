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
        requestHealthKitAuthorization()
        Task { await WorkoutService().cleanupStaleSessions() }
    }

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottom) {
                Color.ink0.ignoresSafeArea()

                tabContent
                    // Reserve room at the bottom so content never sits
                    // underneath the floating capsule tab bar.
                    .padding(.bottom, CapsuleTabBar.reservedHeight)

                CapsuleTabBar(selected: $selectedTab)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        ZStack {
            DashboardView(switchToChatTab: { selectedTab = .coach })
                .opacity(selectedTab == .home ? 1 : 0)
                .allowsHitTesting(selectedTab == .home)

            CoachChatView()
                .opacity(selectedTab == .coach ? 1 : 0)
                .allowsHitTesting(selectedTab == .coach)

            NavigationStack {
                WorkoutModeView()
            }
            .opacity(selectedTab == .train ? 1 : 0)
            .allowsHitTesting(selectedTab == .train)

            HistoryView()
                .opacity(selectedTab == .history ? 1 : 0)
                .allowsHitTesting(selectedTab == .history)

            SettingsView()
                .opacity(selectedTab == .settings ? 1 : 0)
                .allowsHitTesting(selectedTab == .settings)
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

// MARK: - Capsule tab bar
//
// Floating instrument-panel bar: blurred ink surface with a machined
// top-highlight border. Every tab shows its icon plus a small mono label;
// the active tab glows signal-lime with a matched-geometry highlight that
// slides between items.

struct CapsuleTabBar: View {
    @Binding var selected: FitnessCoachApp.Tab
    @Namespace private var indicator

    /// Outer space (bar height + bottom inset) the tab bar occupies — used
    /// by the app root to leave room below scrolling content.
    static let reservedHeight: CGFloat = 80

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FitnessCoachApp.Tab.allCases, id: \.self) { tab in
                tabItem(tab)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.ink1.opacity(0.86))
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 30, style: .continuous)
                    )
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.10), Color.line],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
        )
        .shadow(color: Color.black.opacity(0.55), radius: 22, x: 0, y: 12)
    }

    private func tabItem(_ tab: FitnessCoachApp.Tab) -> some View {
        let isSelected = selected == tab
        return Button {
            guard selected != tab else { return }
            Haptic.light()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selected = tab }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.signal : Color.fg2)
                    .shadow(color: isSelected ? Color.signal.opacity(0.6) : .clear, radius: 7)

                Text(tab.title.uppercased())
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .kerning(0.8)
                    .foregroundStyle(isSelected ? Color.signal : Color.fg3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.signal.opacity(0.09))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(Color.signal.opacity(0.18), lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "activeTab", in: indicator)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
