// SettingsView.swift
// Vaux
//
// Settings as a ruled ledger in the editorial language: eyebrow section
// titles with a fact on the right, hairline rows, Anton for the figures, and
// one lime text action per section. Every control of the previous card
// layout is kept — name, mesocycle position, exercise
// library, HealthKit sync, backend config, about.

import Foundation
import SwiftUI
import UIKit

struct SettingsView: View {
    @State private var mesocycleWeek = 1
    @State private var mesocycleDay = 1
    /// 5 on a bulk (four loading weeks and a deload), 4 on a cut.
    @State private var blockWeeks = Config.mesocycleWeeks
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
    @FocusState private var nameFocused: Bool
    /// Written straight through to UserDefaults, so the dashboard greeting
    /// updates as it's typed with no explicit save step.
    @AppStorage(Config.displayNameKey) private var displayName: String = ""

    private let mesocycleService = MesocycleService()

    struct StatusMessage {
        let text: String
        let isError: Bool
    }

    // Export: the training log as CSV, one file per table, via the share
    // sheet. The state is the status line and the files to share.
    @State private var exportStatus: StatusMessage?
    @State private var exportFiles: [URL] = []
    @State private var isExporting = false

    // Coach flags: the replies flagged as wrong in the last two weeks, as one
    // Markdown text for the share sheet.
    @State private var flagsStatus: StatusMessage?
    @State private var flagsMarkdown: String?
    @State private var isLoadingFlags = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.ink0.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        topBar
                        nameBlock
                        blockSection
                        librarySection
                        exportSection
                        flagsSection
                        healthSection
                        liveActivitySection
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
            sectionHeader("Training block", right: "\(blockWeeks)-week mesocycle")

            ledgerRow(first: true, height: 58) {
                rowLabel("Block length")
                Spacer()
                stepper(value: $blockWeeks, range: 4...5, label: "weeks")
            }
            ledgerRow(height: 58) {
                rowLabel("Week")
                Spacer()
                stepper(value: $mesocycleWeek, range: 1...blockWeeks, label: "week")
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

    private static func phaseLabel(week: Int) -> String? { Config.phaseName(week: week) }

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

    // MARK: - Export

    /// Every table the training log lives in, as CSV, for the share sheet.
    /// Six months of training sits in one database; this is the copy the
    /// athlete owns, and what any analysis outside the app starts from.
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Export")
            Text("Sessions, sets, recovery, standing decisions and plan decisions, one CSV each. Chat history is not included.")
                .font(.system(size: 13))
                .foregroundStyle(Color.fg2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Editorial.gutter)
                .padding(.top, 12)
            HStack {
                if let status = exportStatus { statusLabel(status) }
                Spacer()
                if !exportFiles.isEmpty {
                    ShareLink(items: exportFiles) {
                        Text("Share \(exportFiles.count) files →")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.signal)
                    }
                } else {
                    linkButton(isExporting ? "Exporting…" : "Export training log →") {
                        guard !isExporting else { return }
                        Haptic.light()
                        Task { await runExport() }
                    }
                    .disabled(isExporting)
                }
            }
            .frame(height: 44)
            .padding(.horizontal, Editorial.gutter)
        }
    }

    private var flagsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Coach flags")
            Text("Replies you flagged as wrong in the last 14 days, with the card, the sets and what the reply contract did. One text to share.")
                .font(.system(size: 13))
                .foregroundStyle(Color.fg2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Editorial.gutter)
                .padding(.top, 12)
            HStack {
                if let status = flagsStatus { statusLabel(status) }
                Spacer()
                if let flagsMarkdown {
                    ShareLink(item: flagsMarkdown) {
                        Text("Share →")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.signal)
                    }
                } else {
                    linkButton(isLoadingFlags ? "Loading…" : "Load coach flags →") {
                        guard !isLoadingFlags else { return }
                        Haptic.light()
                        Task { await loadFlags() }
                    }
                    .disabled(isLoadingFlags)
                }
            }
            .frame(height: 44)
            .padding(.horizontal, Editorial.gutter)
        }
    }

    private func loadFlags() async {
        isLoadingFlags = true
        flagsStatus = StatusMessage(text: "Reading…", isError: false)
        do {
            let result = try await ChatService().coachFlags(days: 14)
            flagsMarkdown = result.markdown
            flagsStatus = StatusMessage(text: result.count == 0 ? "No flags in 14 days" : "\(result.count) flag\(result.count == 1 ? "" : "s")", isError: false)
        } catch {
            flagsStatus = StatusMessage(text: "Could not load: \(error.localizedDescription)", isError: true)
        }
        isLoadingFlags = false
    }

    private func runExport() async {
        isExporting = true
        exportFiles = []
        exportStatus = StatusMessage(text: "Reading…", isError: false)
        do {
            let result = try await ExportService().exportAll { table in
                exportStatus = StatusMessage(text: "Reading \(table)…", isError: false)
            }
            let total = result.rowCounts.values.reduce(0, +)
            exportFiles = result.files
            exportStatus = StatusMessage(text: "\(total) rows in \(result.files.count) files", isError: false)
        } catch {
            exportStatus = StatusMessage(text: "Export failed: \(error.localizedDescription)", isError: true)
        }
        isExporting = false
    }

    // MARK: - Live Activity

    /// The rest countdown on the Lock Screen has failed silently more than
    /// once, and every reason it can fail looks the same from the gym floor:
    /// nothing appears. The controller now records what its last request did;
    /// this ledger shows it, beside the two facts the request cannot see —
    /// whether the iOS setting is on and whether the widget extension is in
    /// the build — and a 30-second test that runs the real path without
    /// logging a set.
    private var liveActivitySection: some View {
        let controller = RestActivityController.shared
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Live Activity")
            ledgerRow(first: true, height: 46) {
                rowLabel("iOS setting")
                Spacer()
                rowValue(controller.isAvailable ? "On" : "Off",
                         color: controller.isAvailable ? .fg0 : .ember)
            }
            ledgerRow(height: 46) {
                rowLabel("Widget extension")
                Spacer()
                rowValue(controller.isExtensionInstalled ? "In this build" : "Missing",
                         color: controller.isExtensionInstalled ? .fg0 : .ember)
            }
            ledgerRow(height: 46) {
                rowLabel("Held by iOS")
                Spacer()
                rowValue("\(controller.liveCount)")
            }
            VStack(alignment: .leading, spacing: 6) {
                EditorialEyebrow(text: "Last request", color: Editorial.muted, size: 9.5, kerning: 1.5)
                Text(controller.lastEvent)
                    .font(.system(size: 12.5))
                    .foregroundStyle(controller.lastEventWasError ? Color.ember : Color.fg1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
            .padding(.horizontal, Editorial.gutter)
            HStack {
                linkButton("Test for 30 seconds →") {
                    Haptic.light()
                    controller.startTest()
                }
                Spacer()
                if !controller.isAvailable {
                    linkButton("Open iOS Settings →", color: .mint) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
            .frame(height: 44)
            .padding(.horizontal, Editorial.gutter)
        }
    }

    // MARK: - About

    /// Read from the bundle rather than restated here. The literal this
    /// replaces said "1.0.0" while the project's MARKETING_VERSION said 1.0 —
    /// already drifted, in the one place a reader would trust it, which is the
    /// argument against keeping a second copy of a number Xcode already owns.
    private static let appVersion: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("About")
            ledgerRow(first: true, height: 46) {
                rowLabel("Version")
                Spacer()
                rowValue(Self.appVersion)
            }
            ledgerRow(height: 46) {
                rowLabel("Coach")
                Spacer()
                // Restated, not derived: the model is chosen server-side in
                // coach.py, which the app never sees. Change both together.
                rowValue("Claude Sonnet 5")
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

    private func rowValue(_ text: String, color: Color = .fg0) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
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
            if blockWeeks != Config.mesocycleWeeks {
                try await mesocycleService.saveBlockWeeks(blockWeeks)
            }
            let state = MesocycleState(day: mesocycleDay, week: min(mesocycleWeek, blockWeeks))
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
            blockWeeks = Config.mesocycleWeeks
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
