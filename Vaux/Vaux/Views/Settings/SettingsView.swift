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
    @State private var isBackfilling = false
    @State private var syncStatus: StatusMessage?
    @State private var saveStatus: StatusMessage?
    @State private var lastSyncAt: Date? = HealthKitManager.shared.lastSyncDate
    @State private var briefingStyle: BriefingStyle = .detailed
    @State private var briefingStatus: StatusMessage?

    private let mesocycleService = MesocycleService()
    private let preferences = PreferencesService()

    struct StatusMessage {
        let text: String
        let isError: Bool
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TechBackground(accent: .signal)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        ScreenHeader(
                            eyebrow: "System configuration",
                            title: "Settings"
                        )
                        .padding(.horizontal, 4)
                        .padding(.top, 8)

                        profileHeader
                        mesocycleCard
                        coachStyleCard
                        exerciseLibraryCard
                        healthCard
                        backendCard
                        aboutCard
                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 18)
                }
            }
            .navigationBarHidden(true)
            .task {
                await loadMesocycle()
                briefingStyle = await preferences.loadBriefingStyle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mesocycleDidChange)) { _ in
                // Keep the stepper in sync with `advance()` calls fired from
                // workout completion, so reopening Settings doesn't show a
                // day behind what the rest of the app is using.
                Task { await loadMesocycle() }
            }
        }
    }

    // MARK: - Coach style

    private var coachStyleCard: some View {
        settingsCard(title: "Briefing style") {
            Text("Sets the tone of your morning briefing — used by both the in-app Briefing button and the Telegram morning auto.")
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)

            ForEach(BriefingStyle.allCases) { style in
                Button {
                    Haptic.selection()
                    let previous = briefingStyle
                    briefingStyle = style
                    Task {
                        do {
                            try await preferences.saveBriefingStyle(style)
                            briefingStatus = StatusMessage(text: "Saved", isError: false)
                        } catch {
                            briefingStyle = previous
                            briefingStatus = StatusMessage(
                                text: "Failed: \(error.localizedDescription)",
                                isError: true
                            )
                        }
                    }
                } label: {
                    styleRow(style: style, selected: briefingStyle == style)
                }
                .buttonStyle(.plain)
            }

            if let status = briefingStatus {
                statusLabel(status)
            }
        }
    }

    private func styleRow(style: BriefingStyle, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selected ? Color.signal : Color.fg2)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(style.displayName)
                    .font(.uiStrong)
                    .foregroundStyle(Color.fg0)
                Text(style.blurb)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.fg1)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.signal.opacity(0.06) : Color.ink1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Color.signal.opacity(0.35) : Color.line, lineWidth: 1)
        )
    }

    // MARK: - Exercise library

    private var exerciseLibraryCard: some View {
        settingsCard(title: "Exercise library") {
            Text("Manage the exercises Vaux recognises when you log a set.")
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)

            NavigationLink(destination: ExerciseLibraryView()) {
                HStack {
                    Text("Open library")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.fg0)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.fg2)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.ink3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.line2, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Profile header

    private var profileHeader: some View {
        HStack(spacing: 14) {
            VauxLogo(size: 48)
                .shadow(color: .signal.opacity(0.3), radius: 12, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text("Vaux")
                    .font(.serifBrand)
                    .foregroundStyle(Color.fg0)
                Text("AI FITNESS COACH")
                    .font(.eyebrowSmall)
                    .kerning(1.4)
                    .foregroundStyle(Color.fg2)
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
                // 1...4 — the programme is a repeating 4-week mesocycle.
                // This was 1...6, which let the week-counter overflow bug
                // ("Week 6 of 4") be entered and saved by hand too.
                Stepper("", value: $mesocycleWeek, in: 1...Config.mesocycleWeeks)
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
                    .font(.uiBody)
                    .foregroundStyle(Color.fg1)
                Spacer()
                let type = Config.cycle[(mesocycleDay - 1) % Config.cycleLength]
                Text(type.uppercased())
                    .font(.eyebrowSmall)
                    .kerning(1.0)
                    .foregroundStyle(Color.forSession(type))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.forSession(type).opacity(0.10)))
                    .overlay(Capsule().stroke(Color.forSession(type).opacity(0.22), lineWidth: 1))
            }

            Button {
                Haptic.medium()
                Task { await saveMesocycle() }
            } label: {
                primaryButtonLabel("Save mesocycle")
            }
            .buttonStyle(PressScaleStyle())

            if let status = saveStatus {
                statusLabel(status)
            }
        }
    }

    // MARK: - Health

    private var healthCard: some View {
        settingsCard(title: "Apple Health") {
            Text("Syncs HRV, sleep, heart rate, steps, weight, body fat, and exercise minutes. Background sync updates Vaux automatically when new data lands.")
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)

            if let last = lastSyncAt {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.textTertiary)
                    Text("Last synced \(Self.relativeFormatter.localizedString(for: last, relativeTo: Date()))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
            }

            Button {
                Haptic.medium()
                Task { await syncHealthData() }
            } label: {
                primaryButtonLabel(isSyncing ? "Syncing…" : "Sync now", icon: "arrow.clockwise", busy: isSyncing)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(isSyncing || isBackfilling)

            Button {
                Haptic.light()
                Task { await backfillLastWeek() }
            } label: {
                secondaryButtonLabel(isBackfilling ? "Back-filling…" : "Back-fill last 7 days", icon: "calendar", busy: isBackfilling)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(isSyncing || isBackfilling)

            if let status = syncStatus {
                statusLabel(status)
            }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    // MARK: - Backend

    private var backendCard: some View {
        settingsCard(title: "Backend") {
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow(text: "Backend URL")
                TextField("https://…", text: $backendURL)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.fg0)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.ink1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.line, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 5) {
                Eyebrow(text: "API token")
                SecureField("••••••", text: $apiToken)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.fg0)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.ink1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.line, lineWidth: 1)
                    )
            }

            Button {
                Haptic.light()
                UserDefaults.standard.set(backendURL, forKey: "backendURL")
                UserDefaults.standard.set(apiToken, forKey: "appAPIToken")
                SupabaseClient.reconfigure()
            } label: {
                secondaryButtonLabel("Save")
            }
            .buttonStyle(PressScaleStyle())
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
            Eyebrow(text: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .darkCard(padding: 0, cornerRadius: 18)
    }

    /// Filled signal-lime button — the single primary action of a card.
    private func primaryButtonLabel(_ text: String, icon: String? = nil, busy: Bool = false) -> some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().tint(Color.signalInk).scaleEffect(0.85)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
            }
            Text(text)
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(Color.signalInk)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.signal)
        )
    }

    /// Quiet bordered button — secondary actions.
    private func secondaryButtonLabel(_ text: String, icon: String? = nil, busy: Bool = false) -> some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().tint(Color.fg0).scaleEffect(0.85)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Color.fg0)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ink3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.line2, lineWidth: 1)
        )
    }

    private func row<Accessory: View>(label: String, value: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Text(label)
                .font(.uiBody)
                .foregroundStyle(Color.fg1)
            Spacer()
            Text(value)
                .font(.numSM)
                .foregroundStyle(Color.fg0)
            accessory()
                .fixedSize()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.uiBody)
                .foregroundStyle(Color.fg1)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.fg0)
        }
    }

    private func statusLabel(_ status: StatusMessage) -> some View {
        HStack(spacing: 6) {
            Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
            Text(status.text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(status.isError ? Color.ember : Color.mint)
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
            lastSyncAt = HealthKitManager.shared.lastSyncDate
            Haptic.success()
        } catch {
            syncStatus = StatusMessage(text: "Failed: \(error.localizedDescription)", isError: true)
            Haptic.error()
        }
        isSyncing = false
    }

    private func backfillLastWeek() async {
        isBackfilling = true
        syncStatus = StatusMessage(text: "Back-filling last 7 days…", isError: false)
        do {
            try await HealthKitManager.shared.syncRecent(days: 7)
            syncStatus = StatusMessage(text: "Back-filled 7 days", isError: false)
            lastSyncAt = HealthKitManager.shared.lastSyncDate
            Haptic.success()
        } catch {
            syncStatus = StatusMessage(text: "Failed: \(error.localizedDescription)", isError: true)
            Haptic.error()
        }
        isBackfilling = false
    }
}
