import SwiftUI

struct HistoryView: View {
    @State private var viewModel = HistoryViewModel()
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $selectedTab) {
                    Text("Workouts").tag(0)
                    Text("Recovery").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                ScrollView {
                    switch selectedTab {
                    case 0:
                        workoutsView
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

    private var workoutsView: some View {
        LazyVStack(spacing: 12) {
            if viewModel.sessions.isEmpty && !viewModel.isLoading {
                Text("No workout sessions yet")
                    .foregroundColor(.gray)
                    .padding(.top, 40)
            }
            ForEach(viewModel.sessions) { session in
                SessionCard(session: session)
            }

            if !viewModel.sessions.isEmpty {
                ProgressionChart(sessions: viewModel.sessions)
                    .padding(.top, 8)
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
            TrendChart(title: "HRV", data: hrvData, color: Color.recoveryGreen, unit: "ms")

            let weightData = viewModel.recoveryHistory.compactMap { r -> TrendDataPoint? in
                guard let w = r.weightKg else { return nil }
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                guard let d = f.date(from: r.date) else { return nil }
                return TrendDataPoint(date: d, value: w)
            }
            TrendChart(title: "Weight", data: weightData, color: Color.recoveryYellow, unit: "kg")

            RecoveryTimeline(history: viewModel.recoveryHistory)
        }
        .padding(.horizontal)
    }
}
