// SettingsView.swift
// Vaux
//
// Grouped settings with a profile header, mesocycle position, HealthKit sync,
// backend config, and about info.

import SwiftUI

struct SettingsView: View {
    @State private var mesocycleWeek = 1
    @State private var mesocycleDay = 1
    @State private var backendURL = Config.backendURL
    @State private var apiToken = Config.appAPIToken
    @State private var isSyncing = false
    @State private var syncStatus: StatusMessage?
    @State private var saveStatus: StatusMessage?

    private let mesocycleService = MesocycleService()

    struct StatusMessage {
        let text: String
        let isError: Bool
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        profileHeader
                        mesocycleCard
                        healthCard
                        backendCard
                        aboutCard
                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 18)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .task { await loadMesocycle() }
        }
    }

    // MARK: - Profile header

    private var profileHeader: some View {
        HStack(spacing: 14) {
            VauxLogo(size: 48)
                .shadow(color: .recoveryGreen.opacity(0.4), radius: 12, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text("Vaux")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("AI Fitness Coach")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 0, cornerRadius: 18)
    }

    // MARK: - Mesocycle

    private var mesocycleCard: some View {
        settingsCard(title: "Mesocycle") {
            row(label: "Week", value: "\(mesocycleWeek)") {
                Stepper("", value: $mesocycleWeek, in: 1...6)
                    .labelsHidden()
            }

            Divider().background(Color.cardBorder)

            row(label: "Day", value: "\(mesocycleDay)") {
                Stepper("", value: $mesocycleDay, in: 1...Config.cycleLength)
                    .labelsHidden()
            }

            Divider().background(Color.cardBorder)

            HStack {
                Text("Today's session")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                let type = Config.cycle[(mesocycleDay - 1) % Config.cycleLength]
                Text(type)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.forSession(type))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.forSession(type).opacity(0.14)))
            }

            Button {
                Haptic.medium()
                Task { await saveMesocycle() }
            } label: {
                Text("Save mesocycle")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Gradients.recovery)
                    )
            }

            if let status = saveStatus {
                statusLabel(status)
            }
        }
    }

    // MARK: - Health

    private var healthCard: some View {
        settingsCard(title: "Apple Health") {
            Text("Syncs today's HRV, sleep, heart rate, steps, weight, and body fat from Apple Health into your recovery log.")
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)

            Button {
                Haptic.medium()
                Task { await syncHealthData() }
            } label: {
                HStack(spacing: 8) {
                    if isSyncing {
                        ProgressView().tint(.black).scaleEffect(0.85)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                    }
                    Text(isSyncing ? "Syncing…" : "Sync now")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Gradients.cool)
                )
            }
            .disabled(isSyncing)

            if let status = syncStatus {
                statusLabel(status)
            }
        }
    }

    // MARK: - Backend

    private var backendCard: some View {
        settingsCard(title: "Backend") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Backend URL")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.textTertiary)
                TextField("https://…", text: $backendURL)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.surface)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API token")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.textTertiary)
                SecureField("••••••", text: $apiToken)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.surface)
                    )
            }

            Button {
                Haptic.light()
                UserDefaults.standard.set(backendURL, forKey: "backendURL")
                UserDefaults.standard.set(apiToken, forKey: "appAPIToken")
                SupabaseClient.reconfigure()
            } label: {
                Text("Save")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.surfaceRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.cardBorder, lineWidth: 0.5)
                    )
            }
        }
    }

    // MARK: - About

    private var aboutCard: some View {
        VStack(spacing: 14) {
            settingsCard(title: "About") {
                infoRow("Version", "1.0.0")
                Divider().background(Color.cardBorder)
                infoRow("Coach", "Claude Sonnet 4.6")
            }
            VauxBrandFooter()
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .kerning(1)
                .foregroundStyle(Color.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .darkCard(padding: 0, cornerRadius: 18)
    }

    private func row<Accessory: View>(label: String, value: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
            accessory()
                .fixedSize()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private func statusLabel(_ status: StatusMessage) -> some View {
        HStack(spacing: 6) {
            Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
            Text(status.text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(status.isError ? Color.recoveryRed : Color.recoveryGreen)
    }

    // MARK: - Actions

    private func saveMesocycle() async {
        do {
            let state = MesocycleState(day: mesocycleDay, week: mesocycleWeek)
            try await mesocycleService.saveState(state)
            saveStatus = StatusMessage(text: "Saved", isError: false)
            Haptic.success()
        } catch {
            saveStatus = StatusMessage(text: "Failed: \(error.localizedDescription)", isError: true)
            Haptic.error()
        }
    }

    private func loadMesocycle() async {
        if let state = try? await mesocycleService.loadState() {
            mesocycleWeek = state.week
            mesocycleDay = state.day
        }
    }

    private func syncHealthData() async {
        isSyncing = true
        syncStatus = StatusMessage(text: "Syncing…", isError: false)
        do {
            try await HealthKitManager.shared.syncToSupabase()
            syncStatus = StatusMessage(text: "Synced successfully", isError: false)
            Haptic.success()
        } catch {
            syncStatus = StatusMessage(text: "Failed: \(error.localizedDescription)", isError: true)
            Haptic.error()
        }
        isSyncing = false
    }
}
