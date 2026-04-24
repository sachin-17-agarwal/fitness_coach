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
        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.backgroundColor = UIColor(Color.ink0)
        navBarAppearance.titleTextAttributes = [
            .foregroundColor: UIColor(Color.fg0),
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
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

// MARK: - Capsule tab bar (editorial)
//
// Fixed-height floating capsule at the bottom, ink-2 @ ~82% alpha with blur,
// r=28, 16pt outer inset. Active tab: signal lime icon + label, others fg-2
// icon with no label. Deliberately constrained in height so the bar never
// fights the content area above it (previous implementation had no height
// bound and could stretch when layout changed).

struct CapsuleTabBar: View {
    @Binding var selected: FitnessCoachApp.Tab

    /// Outer space (bar height + bottom inset) the tab bar occupies — used
    /// by the app root to leave room below scrolling content.
    static let reservedHeight: CGFloat = 72

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FitnessCoachApp.Tab.allCases, id: \.self) { tab in
                tabItem(tab)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.ink2.opacity(0.82))
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                    )
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.line, lineWidth: 1)
            }
        )
        .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
    }

    private func tabItem(_ tab: FitnessCoachApp.Tab) -> some View {
        let isSelected = selected == tab
        return Button {
            guard selected != tab else { return }
            Haptic.light()
            withAnimation(.easeOut(duration: 0.18)) { selected = tab }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.signal : Color.fg2)

                if isSelected {
                    Text(tab.title.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .kerning(1.2)
                        .foregroundStyle(Color.signal)
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .padding(.horizontal, isSelected ? 14 : 10)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                Capsule()
                    .fill(isSelected ? Color.signal.opacity(0.08) : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(
                        isSelected ? Color.signal.opacity(0.22) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
