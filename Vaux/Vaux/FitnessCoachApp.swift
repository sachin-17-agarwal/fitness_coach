// FitnessCoachApp.swift
// Vaux
//
// Info.plist entries required:
//   NSHealthShareUsageDescription - "Vaux reads your health data (HRV, heart rate, sleep, steps, VO2 max) to provide personalised recovery and training insights."
//   NSHealthUpdateUsageDescription - "Vaux writes workout data to Apple Health so your training history stays in sync."

import SwiftUI
import HealthKit

@main
struct FitnessCoachApp: App {
    @State private var selectedTab: Tab = .dashboard

    init() {
        configureNavBarAppearance()
        requestHealthKitAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.background.ignoresSafeArea()
                tabContent
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FloatingTabBar(selectedTab: $selectedTab)
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
                .opacity(selectedTab == .dashboard ? 1 : 0)
                .allowsHitTesting(selectedTab == .dashboard)

            CoachChatView()
                .opacity(selectedTab == .coach ? 1 : 0)
                .allowsHitTesting(selectedTab == .coach)

            NavigationStack {
                WorkoutModeView()
            }
            .opacity(selectedTab == .workout ? 1 : 0)
            .allowsHitTesting(selectedTab == .workout)

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
        case dashboard, coach, workout, history, settings

        func icon(selected: Bool) -> String {
            switch self {
            case .dashboard: return selected ? "heart.text.square.fill" : "heart.text.square"
            case .coach:     return "sparkles"
            case .workout:   return "figure.strengthtraining.traditional"
            case .history:   return "chart.xyaxis.line"
            case .settings:  return selected ? "gearshape.fill" : "gearshape"
            }
        }
    }

    // MARK: - Appearance

    private func configureNavBarAppearance() {
        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.backgroundColor = UIColor(Color.background)
        navBarAppearance.titleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
        navBarAppearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor.white,
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
                if HealthKitManager.shared.lastSyncDate == nil {
                    try await HealthKitManager.shared.syncRecent(days: 7)
                } else {
                    try await HealthKitManager.shared.syncToSupabase()
                }
            } catch {
                print("[HealthKit] Startup sync failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Floating tab bar

struct FloatingTabBar: View {
    @Binding var selectedTab: FitnessCoachApp.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FitnessCoachApp.Tab.allCases, id: \.self) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.cardBorder.opacity(0.9), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 8)
        )
        .padding(.horizontal, 20)
    }

    private func tabButton(for tab: FitnessCoachApp.Tab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            guard selectedTab != tab else { return }
            Haptic.selection()
            withAnimation(Motion.spring) { selectedTab = tab }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.recoveryGreen.opacity(isSelected ? 0.12 : 0))
                    .padding(3)
                    .animation(Motion.spring, value: isSelected)

                VStack(spacing: 4) {
                    Image(systemName: tab.icon(selected: isSelected))
                        .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.recoveryGreen : Color.textTertiary)
                        .animation(Motion.snappy, value: isSelected)

                    Circle()
                        .fill(Color.recoveryGreen)
                        .frame(width: 4, height: 4)
                        .opacity(isSelected ? 1 : 0)
                        .animation(Motion.spring, value: isSelected)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
