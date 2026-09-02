// SettingsView.swift
// Vaux
//
// Settings as a ruled ledger in the editorial language: eyebrow section
// titles with a fact on the right, hairline rows, Anton for the figures, and
// one lime text action per section. Every control of the previous card
// layout is kept — name, mesocycle position, briefing style, exercise
// library, HealthKit sync, backend config, about.

import SwiftUI

struct SettingsView: View {
    @State private var mesocycleWeek = 1
    @State private var mesocycleDay = 1
    /// Today's manual swap, if one is set — so the session line below the
    /// steppers agrees with the rest of the app.
    @State private var todayOverride: String?
    @State private var backendURL = Config.backendURL
    @State private var apiToken = Config.appAPIToken
    @State private var isSyncing = false
    @State private var isBackfilling = false
    @State private var syncStatus: StatusMessage?
    @State private var saveStatus: StatusMessage?
    @State private var backendStatus: StatusMessage?
    @State private var lastSyncAt: Date? = HealthKitManager.shared.lastSyncDate
    @State private var briefingStyle: BriefingStyle = .detailed
    @State private var briefingStatus: StatusMessage?
    @FocusState private var nameFocused: Bool
    /// Written straight through to UserDefaults, so the dashboard greeting
    /// updates as it's typed with no explicit save step.
    @AppStorage(Config.displayNameKey) private var displayName: String = ""

    private let mesocycleService = MesocycleService()
    private let preferences = PreferencesService()

    struct StatusMessage {
        let text: String
        let isError: Bool
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.ink0.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        topBar
                        nameBlock
                        blockSection
                        briefingSection
                        librarySection
                        healthSection
                        backendSection
                        aboutSection
                        footer
                    }
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarHidden(true)
            .task {
                await loadMesocycle()
                briefingStyle = await preferences.loadBriefingStyle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mesocycleDidChange)) { _ in
                // Keep the steppers in sync with `advance()` calls fired from
                // workout completion, so reopening Settings doesn't show a
                // day behind what the rest of the app is using.
                Task { await loadMesocycle() }
            }
        }
    }

    // MARK: - Top bar and name

    private var topBar: some View {
        HStack {
            EditorialEyebrow(text: "Settings")
            Spacer()
            EditorialEyebrow(text: "Vaux 1.0.0", color: Editorial.muted, size: 9.5, kerning: 1.5)
        }
        .frame(height: 44)
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 4)
    }

    /// The dashboard greeting used to name one person in source. This is
    /// where that name comes from now; blank simply drops the name from the
    /// greeting rather than leaving a placeholder in it.
    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorialEyebrow(text: "Your name · used in the greeting", color: Editorial.muted, size: 9.5, kerning: 1.8)
            HStack(alignment: .firstTextBaseline) {
                TextField("Your name", text: $displayName)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($nameFocused)
                    .font(.display(40))
                    .foregroundStyle(Color.fg0)
                    .accessibilityLabel("Your name, used in the dashboard greeting")
                Button {
                    Haptic.light()
                    nameFocused = true
                } label: {
                    EditorialEyebrow(text: nameFocused ? "Editing" : "Edit", color: Editorial.muted, size: 10, kerning: 2.2)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
            Rectangle().fill(Color.line).frame(height: 1)
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 22)
    }

    // MARK: - Training block

    private var blockSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Training block", right: "\(Config.mesocycleWeeks)-week mesocycle")

            ledgerRow(first: true, height: 58) {
                rowLabel("Week")
                Spacer()
                stepper(value: $mesocycleWeek, range: 1...Config.mesocycleWeeks, label: "week")
            }
            ledgerRow(height: 58) {
                rowLabel("Day")
                Spacer()
                stepper(value: $mesocycleDay, range: 1...Config.cycleLength, label: "day")
            }
            ledgerRow(height: 52) {
                rowLabel("Today’s session")
                Spacer()
                // Through MesocycleState, not the raw rotation, so the yoga
                // rule and any swap are respected here as everywhere else.
                let type = MesocycleState(
                    day: mesocycleDay, week: mesocycleWeek, todayOverride: todayOverride
                ).todayType
                EditorialEyebrow(text: sessionLine(type), color: .signal, size: 10, kerning: 2.2)
            }
            ledgerRow(height: 44) {
                if let status = saveStatus { statusLabel(status) }
                Spacer()
                linkButton("Save block →") {
                    Haptic.medium()
                    Task { await saveMesocycle() }
                }
            }
        }
    }

    private func sessionLine(_ type: String) -> String {
        if let phase = Self.phaseLabel(week: mesocycleWeek) {
            return "\(type) · \(phase)"
        }
        return type
    }

    private static func phaseLabel(week: Int) -> String? {
        switch week {
        case 1: return "Baseline"
        case 2: return "Volume"
        case 3: return "Peak"
        case 4: return "Deload"
        default: return nil
        }
    }

    // MARK: - Briefing style

    private var briefingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Briefing style", right: "In-app and Telegram")

            ForEach(Array(BriefingStyle.allCases.enumerated()), id: \.element.id) { index, style in
                let selected = briefingStyle == style
                Button {
                    Haptic.selection()
                    selectBriefingStyle(style)
                } label: {
                    HStack(alignment: .center, spacing: 14) {
                        Circle()
                            .fill(selected ? Color.signal : Color.clear)
                            .overlay(Circle().stroke(selected ? Color.signal : Color.fg3, lineWidth: 1))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(style.displayName)
                                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.fg0 : Color.fg1)
                            Text(style.blurb)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.fg3)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(Color.line).frame(height: 1) }
                }
                .padding(.horizontal, Editorial.gutter)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }

            if let status = briefingStatus {
                statusLabel(status)
                    .padding(.horizontal, Editorial.gutter)
                    .padding(.top, 8)
            }
        }
    }

    private func selectBriefingStyle(_ style: BriefingStyle) {
        let previous = briefingStyle
        briefingStyle = style
        Task {
            do {
                try await preferences.saveBriefingStyle(style)
                briefingStatus = StatusMessage(text: "Saved", isError: false)
            } catch {
                briefingStyle = previous
                briefingStatus = StatusMessage(text: "Failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Exercise library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Exercise library")
            NavigationLink(destination: ExerciseLibraryView()) {
                HStack {
                    rowLabel("What Vaux recognises when you log a set")
                    Spacer()
                    EditorialEyebrow(text: "Open ›", color: Editorial.mid, size: 10, kerning: 2.2)
                }
                .frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Editorial.gutter)
        }
    }

    // MARK: - Apple Health

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Apple Health", right: lastSyncLine)

            Text("HRV, sleep, heart rate, steps, weight, body fat and exercise minutes. Background sync updates Vaux when new data lands.")
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(Color.fg2)
                .padding(.horizontal, Editorial.gutter)
                .padding(.top, 12)
                .padding(.bottom, 12)

            ledgerRow(height: 48) {
                linkButton(isSyncing ? "Syncing…" : "Sync now →", busy: isSyncing) {
                    Haptic.medium()
                    Task { await syncHealthData() }
                }
                .disabled(isSyncing || isBackfilling)
                Spacer()
                linkButton(isBackfilling ? "Back-filling…" : "Back-fill 7 days →", color: Editorial.mid, busy: isBackfilling) {
                    Haptic.light()
                    Task { await backfillLastWeek() }
                }
                .disabled(isSyncing || isBackfilling)
            }

            if let status = syncStatus {
                statusLabel(status)
                    .padding(.horizontal, Editorial.gutter)
                    .padding(.top, 6)
            }
        }
    }

    private var lastSyncLine: String {
        guard let last = lastSyncAt else { return "Never synced" }
        return "Last sync \(Self.relativeFormatter.localizedString(for: last, relativeTo: Date()))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    // MARK: - Backend

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Backend")

            VStack(alignment: .leading, spacing: 8) {
                EditorialEyebrow(text: "URL", color: Editorial.muted, size: 9.5, kerning: 1.8)
                TextField("https://…", text: $backendURL)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.fg0)
                    .padding(.bottom, 10)
                Rectangle().fill(Color.line).frame(height: 1)
            }
            .padding(.horizontal, Editorial.gutter)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 8) {
                EditorialEyebrow(text: "API token", color: Editorial.muted, size: 9.5, kerning: 1.8)
                SecureField("••••••", text: $apiToken)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.fg0)
                    .padding(.bottom, 10)
                Rectangle().fill(Color.line).frame(height: 1)
            }
            .padding(.horizontal, Editorial.gutter)
            .padding(.top, 18)

            HStack {
                if let status = backendStatus { statusLabel(status) }
                Spacer()
                linkButton("Save →") {
                    Haptic.light()
                    UserDefaults.standard.set(backendURL, forKey: "backendURL")
                    UserDefaults.standard.set(apiToken, forKey: "appAPIToken")
                    SupabaseClient.reconfigure()
                    backendStatus = StatusMessage(text: "Saved", isError: false)
                }
            }
            .frame(height: 44)
            .padding(.horizontal, Editorial.gutter)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("About")
            ledgerRow(first: true, height: 46) {
                rowLabel("Version")
                Spacer()
                rowValue("1.0.0")
            }
            ledgerRow(height: 46) {
                rowLabel("Coach")
                Spacer()
                rowValue("Claude Sonnet 4.6")
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("VAUX")
                .font(.display(22))
                .kerning(1)
                .foregroundStyle(Color.ink4)
            Spacer()
            EditorialEyebrow(text: "AI fitness coach", color: Color.ink4, size: 9.5, kerning: 2.5)
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 40)
        .accessibilityHidden(true)
    }

    // MARK: - Building blocks

    private func sectionHeader(_ title: String, right: String = "") -> some View {
        HStack(alignment: .firstTextBaseline) {
            EditorialEyebrow(text: title)
            Spacer()
            if !right.isEmpty {
                EditorialEyebrow(text: right, color: Editorial.muted, size: 9.5, kerning: 1.5)
            }
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 26)
    }

    private func ledgerRow<Content: View>(
        first: Bool = false, height: CGFloat = 52, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            content()
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Color.line).frame(height: 1) }
        }
        .padding(.horizontal, Editorial.gutter)
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Color.fg1)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func rowValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.fg0)
    }

    /// Round − / + controls around an Anton figure.
    private func stepper(value: Binding<Int>, range: ClosedRange<Int>, label: String) -> some View {
        HStack(spacing: 14) {
            roundStep("minus", enabled: value.wrappedValue > range.lowerBound, accessibility: "Decrease \(label)") {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1)
            }
            Text("\(value.wrappedValue)")
                .font(.display(26))
                .foregroundStyle(Color.fg0)
                .frame(minWidth: 22)
                .contentTransition(.numericText())
                .accessibilityLabel("\(label.capitalized) \(value.wrappedValue)")
            roundStep("plus", enabled: value.wrappedValue < range.upperBound, accessibility: "Increase \(label)") {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + 1)
            }
        }
    }

    private func roundStep(_ symbol: String, enabled: Bool, accessibility: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptic.selection()
            withAnimation(Motion.snappy) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? Color.fg0 : Color.fg3)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.ink2))
                .overlay(Circle().stroke(Color.line, lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.92))
        .disabled(!enabled)
        .accessibilityLabel(accessibility)
    }

    /// The section's action as a lime eyebrow link, not a filled button.
    private func linkButton(
        _ text: String, color: Color = .signal, busy: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().tint(color).scaleEffect(0.7)
                }
                EditorialEyebrow(text: text, color: color, size: 10, kerning: 2.2)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusLabel(_ status: StatusMessage) -> some View {
        Text(status.text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(status.isError ? Color.ember : Color.mint)
            .lineLimit(2)
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
            todayOverride = state.todayOverride
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
