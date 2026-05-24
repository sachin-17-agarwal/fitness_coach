import SwiftUI

struct HistoryView: View {
    @State private var viewModel = HistoryViewModel()
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    tabButton("Training", tag: 0)
                    tabButton("Volume", tag: 1)
                    tabButton("Recovery", tag: 2)
                }
                .padding(3)
                .background(Color.cardBackground)
                .clipShape(Capsule())
                .padding(.horizontal)
                .padding(.vertical, 12)

                ScrollView(showsIndicators: false) {
                    switch selectedTab {
                    case 0:
                        workoutsView
                    case 1:
                        volumeView
                    default:
                        recoveryView
                    }
                }
            }
            .background(Color.background)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await viewModel.load() }
            .task { await viewModel.load() }
        }
    }

    private func tabButton(_ title: String, tag: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedTab = tag
            }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: selectedTab == tag ? .bold : .medium))
                .foregroundStyle(selectedTab == tag ? .black : Color.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selectedTab == tag ? Color.recoveryGreen : .clear)
                .clipShape(Capsule())
        }
    }

    private var workoutsView: some View {
        LazyVStack(spacing: 12) {
            if viewModel.sessions.isEmpty && !viewModel.isLoading {
                emptyState(icon: "figure.strengthtraining.traditional", text: "No workout sessions yet")
            }
            ForEach(Array(viewModel.sessions.enumerated()), id: \.element.id) { index, session in
                SessionCard(session: session)
                    .staggeredAppearance(index: index)
            }
        }
        .padding(.horizontal)
    }

    private var volumeView: some View {
        VStack(spacing: 16) {
            if !viewModel.sessions.isEmpty {
                ProgressionChart(sessions: viewModel.sessions)
            } else {
                emptyState(icon: "chart.line.uptrend.xyaxis", text: "No progression data yet")
            }
        }
        .padding(.horizontal)
    }

    private var recoveryView: some View {
        VStack(spacing: 16) {
            let hrvData = viewModel.recoveryHistory.compactMap { r -> TrendDataPoint? in
                guard let hrv = r.hrv else { return nil }
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                guard let d = f.date(from: r.date) else { return nil }
                return TrendDataPoint(date: d, value: hrv)
            }
            if !hrvData.isEmpty {
                TrendChart(title: "HRV", data: hrvData, color: Color.recoveryGreen, unit: "ms")
                    .staggeredAppearance(index: 0)
            }

            let rhrData = viewModel.recoveryHistory.compactMap { r -> TrendDataPoint? in
                guard let rhr = r.restingHr else { return nil }
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                guard let d = f.date(from: r.date) else { return nil }
                return TrendDataPoint(date: d, value: rhr)
            }
            if !rhrData.isEmpty {
                TrendChart(title: "Resting HR", data: rhrData, color: Color.recoveryRed, unit: "bpm")
                    .staggeredAppearance(index: 1)
            }

            let weightData = viewModel.recoveryHistory.compactMap { r -> TrendDataPoint? in
                guard let w = r.weightKg else { return nil }
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                guard let d = f.date(from: r.date) else { return nil }
                return TrendDataPoint(date: d, value: w)
            }
            if !weightData.isEmpty {
                TrendChart(title: "Weight", data: weightData, color: Color.recoveryYellow, unit: "kg")
                    .staggeredAppearance(index: 2)
            }

            sectionHeader("DAILY LOG")
                .staggeredAppearance(index: 3)

            RecoveryTimeline(history: viewModel.recoveryHistory)
        }
        .padding(.horizontal)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(Color.textSecondary.opacity(0.5))
            Text(text)
                .font(.subheadline)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
