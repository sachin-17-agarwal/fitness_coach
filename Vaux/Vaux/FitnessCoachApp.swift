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
    @State private var showBriefing = false

    init() {
        configureAppearance()
        requestHealthKitAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                TabView(selection: $selectedTab) {
                    DashboardView(switchToChatTab: { selectedTab = .coach })
                        .tabItem {
                            Label("Home", systemImage: "heart.text.square.fill")
                        }
                        .tag(Tab.dashboard)

                    CoachChatView()
                        .tabItem {
                            Label("Coach", systemImage: "sparkles")
                        }
                        .tag(Tab.coach)

                    NavigationStack {
                        WorkoutModeView()
                    }
                    .tabItem {
                        Label("Workout", systemImage: "figure.strengthtraining.traditional")
                    }
                    .tag(Tab.workout)

                    HistoryView()
                        .tabItem {
                            Label("History", systemImage: "chart.xyaxis.line")
                        }
                        .tag(Tab.history)

                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape.fill")
                        }
                        .tag(Tab.settings)
                }
                .tint(Color.recoveryGreen)
                .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showBriefing) {
                MorningBriefingView(
                    onStartWorkout: { _ in
                        showBriefing = false
                        selectedTab = .workout
                    },
                    onOpenChat: {
                        showBriefing = false
                        selectedTab = .coach
                    }
                )
            }
            .task { await presentDailyBriefingIfNeeded() }
        }
    }

    // MARK: - Tabs

    enum Tab: Hashable {
        case dashboard, coach, workout, history, settings
    }

    // MARK: - Daily briefing

    @MainActor
    private func presentDailyBriefingIfNeeded() async {
        let service = BriefingService()
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 5 && hour < 12 else { return }
        guard !service.hasBeenShownToday() else { return }
        try? await Task.sleep(nanoseconds: 600_000_000)
        showBriefing = true
    }

    // MARK: - Appearance

    private func configureAppearance() {
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor(Color.surface)
        tabBarAppearance.shadowColor = UIColor(Color.cardBorder.opacity(0.6))

        let normal = UITabBarItemAppearance()
        normal.normal.iconColor = UIColor(Color.textTertiary)
        normal.normal.titleTextAttributes = [.foregroundColor: UIColor(Color.textTertiary),
                                             .font: UIFont.systemFont(ofSize: 10, weight: .semibold)]
        normal.selected.iconColor = UIColor(Color.recoveryGreen)
        normal.selected.titleTextAttributes = [.foregroundColor: UIColor(Color.recoveryGreen),
                                               .font: UIFont.systemFont(ofSize: 10, weight: .bold)]
        tabBarAppearance.stackedLayoutAppearance = normal
        tabBarAppearance.inlineLayoutAppearance = normal
        tabBarAppearance.compactInlineLayoutAppearance = normal

        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance

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

        let store = HKHealthStore()

        let readTypes: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.bodyMass),
            HKQuantityType(.bodyFatPercentage),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.vo2Max),
            HKCategoryType(.sleepAnalysis),
        ]

        let writeTypes: Set<HKSampleType> = [
            HKQuantityType(.bodyMass),
            HKQuantityType(.activeEnergyBurned),
        ]

        store.requestAuthorization(toShare: writeTypes, read: readTypes) { success, error in
            if let error {
                print("[HealthKit] Authorization error: \(error.localizedDescription)")
            } else {
                print("[HealthKit] Authorization granted: \(success)")
            }
        }
    }
}
