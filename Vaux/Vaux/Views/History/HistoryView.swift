// HistoryView.swift
// Vaux
//
// Training, Strength, Volume and Recovery as editorial pages: a full-bleed
// hero with the tabs set inside it, one figure, a diagnosis, then poster
// rows. All four read from one load placed on the block calendar.

import SwiftUI

struct HistoryView: View {
    var switchToChatTab: (() -> Void)? = nil

    @State private var viewModel = HistoryViewModel()
    @State private var selectedTab: Tab = .training

    enum Tab: String, CaseIterable {
        case training = "Training"
        case strength = "Strength"
        case volume = "Volume"
        case recovery = "Recovery"
    }

    var body: some View {
        ZStack {
            Editorial.bg.ignoresSafeArea()

            if viewModel.isLoading && !viewModel.hasLoadedOnce {
                loadingState
            } else if let error = viewModel.errorMessage, !viewModel.hasAnyData {
                LoadErrorState(message: error, isRetrying: viewModel.isLoading) {
                    Task { await viewModel.load() }
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let error = viewModel.errorMessage {
                            LoadErrorBanner(message: error)
                                .padding(.horizontal, Editorial.gutter)
                                .padding(.top, 60)
                        }
                        switch selectedTab {
                        case .training:
                            TrainingTabView(vm: viewModel.training, strength: viewModel.strength, recovery: viewModel.recovery,
                                            tab: $selectedTab, askCoach: askCoach)
                        case .strength:
                            StrengthTabView(vm: viewModel.strength, calendar: viewModel.calendar, tab: $selectedTab, askCoach: askCoach,
                                            canLoadEarlier: viewModel.canLoadEarlier, isLoadingEarlier: viewModel.isLoadingEarlier,
                                            loadEarlier: { Task { await viewModel.loadEarlier() } })
                        case .volume:
                            VolumeTabView(vm: viewModel.weeklyVolume, calendar: viewModel.calendar, tab: $selectedTab, askCoach: askCoach)
                        case .recovery:
                            RecoveryTabView(vm: viewModel.recovery, calendar: viewModel.calendar, tab: $selectedTab, askCoach: askCoach,
                                            onRangeChange: { Task { await viewModel.reloadRecovery() } })
                        }
                        Spacer(minLength: Editorial.bottomInset)
                    }
                    .id(selectedTab)
                    .transition(.opacity)
                }
                .ignoresSafeArea(edges: .top)
                .vauxRefreshable { await viewModel.load() }
            }
        }
        .task { await viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: .mesocycleDidChange)) { _ in
            Task { await viewModel.load() }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 18) {
            VauxLogo(size: 34, color: .signal)
            Text("PLACING SESSIONS ON THE BLOCK")
                .font(.eyebrowSmall)
                .kerning(1.6)
                .foregroundStyle(Color.fg2)
        }
    }

    private func askCoach(_ prompt: String) {
        ChatHandoff.shared.pendingPrompt = prompt
        switchToChatTab?()
    }
}
