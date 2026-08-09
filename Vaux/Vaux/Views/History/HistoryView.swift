// HistoryView.swift
// Vaux
//
// Training + recovery history with a custom segmented control, workout
// heatmap, and progression charts.

import SwiftUI

struct HistoryView: View {
    @State private var viewModel = HistoryViewModel()
    @State private var selectedTab: Tab = .training

    enum Tab: String, CaseIterable {
        case training = "Training"
        case strength = "Strength"
        case volume = "Volume"
        case recovery = "Recovery"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TechBackground(accent: .iris)

                VStack(spacing: 0) {
                    ScreenHeader(
                        eyebrow: "Training log",
                        title: "History"
                    )
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                    tabSelector
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 16) {
                            // Each segment reads from a different loader, so
                            // the failure shown has to be the one belonging to
                            // what's on screen — a volume fetch that failed
                            // says nothing about the recovery tab.
                            if let error = currentError, !currentSegmentHasData {
                                // Nothing to show and a reason why: the reason
                                // is the content. The alternative was an empty
                                // state claiming there were no sessions, or a
                                // volume chart reading a flat zero, neither of
                                // which was true.
                                LoadErrorState(message: error, isRetrying: viewModel.isLoading) {
                                    Task { await viewModel.load() }
                                }
                            } else {
                                if let error = currentError {
                                    LoadErrorBanner(message: error)
                                }

                                switch selectedTab {
                                case .training: trainingContent
                                case .strength: strengthContent
                                case .volume: volumeContent
                                case .recovery: recoveryContent
                                }
                            }
                            Spacer(minLength: 20)
                        }
                        .padding(.horizontal, 18)
                    }
                    .refreshable { await viewModel.load() }
                }
            }
            .navigationBarHidden(true)
            .task { await viewModel.load() }
        }
    }

    // MARK: - Per-segment load failure

    /// The error belonging to whichever segment is showing. Training and
    /// Recovery share the screen's own loader; Strength and Volume each run
    /// their own, and roll up separately so a failure in one doesn't blank the
    /// others.
    private var currentError: String? {
        switch selectedTab {
        case .training, .recovery: return viewModel.errorMessage
        case .strength:            return viewModel.muscleStrength.errorMessage
        case .volume:              return viewModel.weeklyVolume.errorMessage
        }
    }

    /// Whether the showing segment has anything to render. Decides between
    /// annotating the data with a banner and replacing it with the failure.
    private var currentSegmentHasData: Bool {
        switch selectedTab {
        case .training: return !viewModel.sessions.isEmpty
        case .recovery: return !viewModel.recoveryHistory.isEmpty
        case .strength: return !viewModel.muscleStrength.muscles.isEmpty
        case .volume:   return viewModel.weeklyVolume.thisWeekSets > 0
        }
    }

    // MARK: - Tab selector

    private var tabSelector: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    Haptic.selection()
                    withAnimation(Motion.snappy) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .kerning(1.0)
                        .foregroundStyle(selectedTab == tab ? Color.signal : Color.fg2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            ZStack {
                                if selectedTab == tab {
                                    Capsule()
                                        .fill(Color.signal.opacity(0.08))
                                        .overlay(
                                            Capsule()
                                                .stroke(Color.signal.opacity(0.22), lineWidth: 1)
                                        )
                                        .matchedGeometryEffect(id: "tabBG", in: tabNamespace)
                                }
                            }
                        )
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(selectedTab == tab ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(
            Capsule().fill(Color.ink2)
        )
        .overlay(
            Capsule().stroke(Color.line, lineWidth: 1)
        )
    }

    @Namespace private var tabNamespace

    // MARK: - Training

    private var trainingContent: some View {
        Group {
            heatmapCard

            summaryRow

            if viewModel.sessions.isEmpty && !viewModel.isLoading {
                emptyTraining
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Recent sessions")
                    ForEach(viewModel.sessionsByDay) { day in
                        SessionCard(
                            sessions: day.sessions,
                            reloadToken: viewModel.reloadToken,
                            // A corrected set changes the window's set count
                            // and tonnage, both derived at load time.
                            onSetsChanged: { Task { await viewModel.load() } }
                        )
                    }
                }

                ProgressionChart()
            }
        }
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow(text: "Training activity")
                Spacer()
                Eyebrow(text: "Last 8 weeks")
            }

            WorkoutHeatmap(sessions: viewModel.sessions)
        }
        .darkCard(padding: 14, cornerRadius: 16)
    }

    private var summaryRow: some View {
        HStack(spacing: 10) {
            miniStat(value: "\(viewModel.sessionsByDay.count)", label: "sessions", color: .recoveryGreen, icon: "figure.strengthtraining.traditional")
            miniStat(value: totalTonnageString, label: "tonnage", color: .accentPurple, icon: "scalemass.fill")
            miniStat(value: "\(setCount)", label: "sets", color: .accentAmber, icon: "number")
        }
    }

    private func miniStat(value: String, label: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(height: 16)
                .accessibilityHidden(true)
            Text(value)
                .font(.numMD)
                .foregroundStyle(Color.fg0)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label.uppercased())
                .font(.eyebrowSmall)
                .kerning(1.2)
                .foregroundStyle(Color.fg2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 14, cornerRadius: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var emptyTraining: some View {
        VStack(spacing: 14) {
            IconBadge(systemName: "figure.strengthtraining.traditional", accent: .signal, size: 64)
            Text("No sessions yet")
                .font(.serifSM)
                .foregroundStyle(Color.fg0)
            Text("START YOUR FIRST WORKOUT IN THE TRAIN TAB")
                .font(.eyebrowSmall)
                .kerning(1.2)
                .foregroundStyle(Color.fg2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - Strength

    private var strengthContent: some View {
        MuscleStrengthView(viewModel: viewModel.muscleStrength)
    }

    // MARK: - Volume

    private var volumeContent: some View {
        WeeklyVolumeView(viewModel: viewModel.weeklyVolume)
    }

    // MARK: - Recovery

    private var recoveryContent: some View {
        Group {
            let hrvData = trendPoints(\.hrv)
            let weightData = trendPoints(\.weightKg)
            let rhrData = trendPoints(\.restingHr)

            if !hrvData.isEmpty {
                TrendChart(title: "HRV", data: hrvData, color: .recoveryGreen, unit: "ms")
            }
            if !rhrData.isEmpty {
                TrendChart(title: "Resting HR", data: rhrData, color: .recoveryRed, unit: "bpm")
            }
            if !weightData.isEmpty {
                TrendChart(title: "Weight", data: weightData, color: .accentAmber, unit: "kg")
            }

            if viewModel.recoveryHistory.isEmpty && !viewModel.isLoading {
                VStack(spacing: 14) {
                    IconBadge(systemName: "waveform.path.ecg", accent: .mint, size: 64)
                    Text("No recovery data")
                        .font(.serifSM)
                        .foregroundStyle(Color.fg0)
                    Text("SYNC APPLE HEALTH OR LOG A WEIGHT TO START")
                        .font(.eyebrowSmall)
                        .kerning(1.2)
                        .foregroundStyle(Color.fg2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Daily log")
                    RecoveryTimeline(history: viewModel.recoveryHistory)
                }
            }
        }
    }

    // MARK: - Helpers

    private func trendPoints(_ key: KeyPath<Recovery, Double?>) -> [TrendDataPoint] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return viewModel.recoveryHistory.compactMap { r in
            guard let value = r[keyPath: key], let date = f.date(from: r.date) else { return nil }
            return TrendDataPoint(date: date, value: value)
        }
    }

    private var totalTonnageString: String {
        let total = viewModel.sessions.compactMap(\.tonnageKg).reduce(0, +)
        if total >= 1000 { return String(format: "%.1ft", total / 1000) }
        return "\(Int(total)) kg"
    }

    private var setCount: Int { viewModel.totalSetsInWindow }
}

// MARK: - Heatmap

struct WorkoutHeatmap: View {
    let sessions: [WorkoutSession]

    private static let weeks = 8
    private static let cellHeight: CGFloat = 14
    private static let spacing: CGFloat = 3

    private var cells: [(date: Date, intensity: Double)] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let sessionByDate: [String: WorkoutSession] = sessions.reduce(into: [:]) { map, s in
            map[s.date] = s
        }

        // Align the grid to real weekdays. Starting it exactly 55 days back
        // made the last cell always land in the bottom row, so "today" was
        // pinned to the row labelled S regardless of the actual day — off by
        // one on a Saturday, off by four on a Wednesday — and the M/W/F/S
        // labels described nothing. Anchor to the Monday of the current week
        // instead, so row index IS the weekday (Mon = 0 ... Sun = 6).
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekdayIndex = (cal.component(.weekday, from: today) + 5) % 7  // Calendar: 1=Sun
        let mondayThisWeek = cal.date(byAdding: .day, value: -weekdayIndex, to: today) ?? today
        let gridStart = cal.date(byAdding: .day, value: -(Self.weeks - 1) * 7, to: mondayThisWeek) ?? today

        return (0..<Self.weeks * 7).map { offset in
            let date = cal.date(byAdding: .day, value: offset, to: gridStart) ?? today
            let key = f.string(from: date)
            let intensity: Double
            if let s = sessionByDate[key] {
                if let tonnage = s.tonnageKg, tonnage > 0 {
                    intensity = min(1, tonnage / 6000)
                } else {
                    intensity = 0.35
                }
            } else {
                intensity = 0
            }
            return (date, intensity)
        }
    }

    private static let dayLabels = ["M", "", "W", "", "F", "", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .trailing, spacing: Self.spacing) {
                    ForEach(0..<7, id: \.self) { dayIdx in
                        Text(Self.dayLabels[dayIdx])
                            .font(.eyebrowSmall)
                            .foregroundStyle(Color.fg2)
                            .frame(height: Self.cellHeight)
                    }
                }
                .frame(width: 16)

                GeometryReader { geo in
                    let cellWidth = (geo.size.width - CGFloat(Self.weeks - 1) * Self.spacing) / CGFloat(Self.weeks)

                    HStack(alignment: .top, spacing: Self.spacing) {
                        ForEach(0..<Self.weeks, id: \.self) { weekIdx in
                            VStack(spacing: Self.spacing) {
                                ForEach(0..<7, id: \.self) { dayIdx in
                                    let cellIdx = weekIdx * 7 + dayIdx
                                    let cell = cells[cellIdx]
                                    let isToday = Calendar.current.isDateInToday(cell.date)
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(cellColor(cell.intensity))
                                        .frame(width: cellWidth, height: Self.cellHeight)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                .stroke(
                                                    isToday ? Color.signal : Color.clear,
                                                    lineWidth: 1
                                                )
                                        )
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 7 * Self.cellHeight + 6 * Self.spacing)
            // 56 unlabelled squares would be 56 stops that each announce
            // nothing. The grid carries one summary instead, and the legend
            // below it only explains the colour coding — which is meaningless
            // without the colours.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Training activity, last 8 weeks")
            .accessibilityValue(activitySummary)

            legend
                .accessibilityHidden(true)
        }
    }

    /// How many of the last 8 weeks' days were trained, and when the most
    /// recent one was.
    private var activitySummary: String {
        let trained = cells.filter { $0.intensity > 0 }
        guard let latest = trained.last?.date else {
            return "No sessions in this window"
        }
        let days = "\(trained.count) day\(trained.count == 1 ? "" : "s") trained"
        if Calendar.current.isDateInToday(latest) {
            return "\(days), most recently today"
        }
        return "\(days), most recently \(latest.formatted(.dateTime.month(.wide).day()))"
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("LESS")
                .font(.eyebrowSmall)
                .kerning(1.0)
                .foregroundStyle(Color.fg3)
            legendSwatch(Color.ink3)
            legendSwatch(Color.signal.opacity(0.25))
            legendSwatch(Color.signal.opacity(0.55))
            legendSwatch(Color.signal)
            Text("MORE")
                .font(.eyebrowSmall)
                .kerning(1.0)
                .foregroundStyle(Color.fg3)

            Spacer()

            legendSwatch(Color.ink3, stroke: Color.signal)
            Text("TODAY")
                .font(.eyebrowSmall)
                .kerning(1.0)
                .foregroundStyle(Color.fg3)
        }
        .padding(.leading, 16)
    }

    private func legendSwatch(_ fill: Color, stroke: Color = .clear) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fill)
            .frame(width: 9, height: 9)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
    }

    private func cellColor(_ intensity: Double) -> Color {
        if intensity <= 0 { return Color.ink3 }
        if intensity < 0.3 { return Color.signal.opacity(0.25) }
        if intensity < 0.6 { return Color.signal.opacity(0.55) }
        return Color.signal
    }
}
