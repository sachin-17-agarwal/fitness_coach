// FitnessCoachApp.swift
// FitnessCoach
//
// Info.plist entries required:
//   NSHealthShareUsageDescription - "FitnessCoach reads your health data (HRV, heart rate, sleep, steps, VO2 max) to provide personalised recovery and training insights."
//   NSHealthUpdateUsageDescription - "FitnessCoach writes workout data to Apple Health so your training history stays in sync."

import SwiftUI
import HealthKit

@main
struct FitnessCoachApp: App {
    @State private var selectedTab: Tab = .dashboard

    init() {
        configureAppearance()
        requestHealthKitAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                DashboardView()
                    .tabItem {
                        Label("Dashboard", systemImage: "heart.text.square")
                    }
                    .tag(Tab.dashboard)

                CoachChatView()
                    .tabItem {
                        Label("Coach", systemImage: "message")
                    }
                    .tag(Tab.coach)

                WorkoutModeView()
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
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(Tab.settings)
            }
            .tint(Color.recoveryGreen)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Tabs

    enum Tab: Hashable {
        case dashboard, coach, workout, history, settings
    }

    // MARK: - Appearance

    private func configureAppearance() {
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor(Color.background)
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance

        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithOpaqueBackground()
        navBarAppearance.backgroundColor = UIColor(Color.background)
        navBarAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navBarAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
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

