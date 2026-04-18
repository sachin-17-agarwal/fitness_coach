import SwiftUI

struct WorkoutSummaryView: View {
    let summary: WorkoutSummary
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Workout Complete")
                    .font(.title.weight(.bold))
                    .foregroundColor(.white)

                HStack(spacing: 24) {
                    summaryItem(value: summary.tonnage.weightString, label: "Tonnage")
                    summaryItem(value: "\(summary.totalSets)", label: "Sets")
                    summaryItem(value: formatDuration(summary.duration), label: "Duration")
                }

                if !summary.prs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Personal Records")
                            .font(.headline)
                            .foregroundColor(Color.recoveryGreen)

                        ForEach(summary.prs.filter(\.isPR), id: \.exercise) { pr in
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundColor(Color.recoveryYellow)
                                Text(pr.exercise)
                                    .foregroundColor(.white)
                                Spacer()
                                Text(pr.estimated1RM.weightString)
                                    .font(.body.weight(.bold).monospacedDigit())
                                    .foregroundColor(Color.recoveryGreen)
                            }
                        }
                    }
                    .padding()
                    .modifier(DarkCardStyle())
                }

                Spacer()

                Button("Done", action: onDismiss)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.recoveryGreen)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding()
            .background(Color.background)
        }
    }

    private func summaryItem(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundColor(.white)
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .modifier(DarkCardStyle())
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
