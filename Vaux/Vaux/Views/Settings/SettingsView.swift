import SwiftUI

struct SettingsView: View {
    @State private var mesocycleWeek = 1
    @State private var mesocycleDay = 1
    @State private var backendURL = Config.backendURL
    @State private var isSyncing = false
    @State private var syncStatus = ""

    private let mesocycleService = MesocycleService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Mesocycle") {
                    Stepper("Week: \(mesocycleWeek)", value: $mesocycleWeek, in: 1...4)
                    Stepper("Day: \(mesocycleDay)", value: $mesocycleDay, in: 1...5)
                    Text("Session: \(Config.cycle[(mesocycleDay - 1) % Config.cycle.count])")
                        .foregroundColor(Color.recoveryGreen)

                    Button("Save Mesocycle") {
                        Task {
                            let state = MesocycleState(day: mesocycleDay, week: mesocycleWeek)
                            try? await mesocycleService.saveState(state)
                        }
                    }
                }

                Section("Backend") {
                    TextField("Railway URL", text: $backendURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save") {
                        UserDefaults.standard.set(backendURL, forKey: "backendURL")
                    }
                }

                Section("Health Data") {
                    Button {
                        Task { await syncHealthData() }
                    } label: {
                        HStack {
                            Text("Sync Now")
                            Spacer()
                            if isSyncing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSyncing)

                    if !syncStatus.isEmpty {
                        Text(syncStatus)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.gray)
                    }
                    HStack {
                        Text("Coach")
                        Spacer()
                        Text("Claude AI")
                            .foregroundColor(.gray)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadMesocycle() }
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
        syncStatus = "Syncing..."
        do {
            try await HealthKitManager.shared.syncToSupabase()
            syncStatus = "Synced successfully"
        } catch {
            syncStatus = "Failed: \(error.localizedDescription)"
        }
        isSyncing = false
    }
}
