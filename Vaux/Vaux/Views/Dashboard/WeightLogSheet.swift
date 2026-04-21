// WeightLogSheet.swift
// Vaux
//
// Quick sheet to log a body-weight reading to the `recovery` table for today.

import SwiftUI

struct WeightLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var weight: Double = 80.0
    @State private var bodyFat: String = ""
    @State private var status: String = ""
    @State private var isSaving = false

    let initialWeight: Double?
    var onSaved: (() -> Void)? = nil

    private let recoveryService = RecoveryService()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.background.ignoresSafeArea()
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("Log your weight")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Today, \(Date().formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.textSecondary)
                    }

                    WeightPicker(weight: $weight)
                        .darkCard()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("BODY FAT %")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .kerning(1.0)
                            .foregroundStyle(Color.textSecondary)
                        TextField("optional", text: $bodyFat)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .padding(14)
                            .background(Color.cardBackground)
                            .foregroundStyle(.white)
                            .cornerRadius(12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !status.isEmpty {
                        Text(status)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(status.contains("Saved") ? Color.recoveryGreen : Color.recoveryRed)
                    }

                    Spacer()

                    Button(action: save) {
                        HStack {
                            if isSaving {
                                ProgressView().tint(.black)
                            } else {
                                Text("Save")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                            }
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Gradients.recovery)
                        )
                    }
                    .disabled(isSaving)
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let initialWeight { weight = initialWeight }
            }
        }
    }

    private func save() {
        Task {
            isSaving = true
            status = ""
            let bf = Double(bodyFat.trimmingCharacters(in: .whitespaces))
            let recovery = Recovery(
                date: RecoveryService.todayString(),
                weightKg: weight,
                bodyFatPct: bf
            )
            do {
                try await recoveryService.saveRecovery(recovery)
                // Mirror the entry into HealthKit so the next background HK
                // sync re-reads the same value instead of overwriting this
                // recovery row with an older sample. Best-effort — if the
                // user declined HK write permission, the Supabase row still
                // wins because body-mass sync is now day-scoped.
                try? await HealthKitManager.shared.saveBodyComposition(
                    weightKg: weight,
                    bodyFatPct: bf
                )
                Haptic.success()
                status = "Saved"
                onSaved?()
                try? await Task.sleep(nanoseconds: 400_000_000)
                dismiss()
            } catch {
                Haptic.error()
                status = "Failed: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}
