import SwiftUI

struct SessionCard: View {
    let session: WorkoutSession
    @State private var sets: [WorkoutSet] = []
    @State private var isExpanded = false

    private let workoutService = WorkoutService()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.type)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.white)
                    Text(session.date)
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()

                if let tonnage = session.tonnageKg {
                    Text(tonnage.weightString)
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundColor(Color.recoveryGreen)
                }

                statusBadge(session.status)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            if isExpanded && !sets.isEmpty {
                let grouped = Dictionary(grouping: sets, by: \.exercise)
                ForEach(grouped.keys.sorted(), id: \.self) { exercise in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Color.recoveryGreen)
                        ForEach(grouped[exercise] ?? [], id: \.setNumber) { s in
                            HStack {
                                Text("Set \(s.setNumber)")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                    .frame(width: 40, alignment: .leading)
                                if let w = s.actualWeightKg, let r = s.actualReps {
                                    Text("\(w.weightString) x\(r)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.white)
                                }
                                if let rpe = s.actualRpe {
                                    Text("@\(rpe.oneDecimal)")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding()
        .modifier(DarkCardStyle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
            if isExpanded && sets.isEmpty {
                Task { await loadSets() }
            }
        }
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status.capitalized)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(status == "completed" ? Color.recoveryGreen.opacity(0.2) : Color.recoveryYellow.opacity(0.2))
            .foregroundColor(status == "completed" ? Color.recoveryGreen : Color.recoveryYellow)
            .clipShape(Capsule())
    }

    private func loadSets() async {
        guard let id = session.id else { return }
        sets = (try? await workoutService.fetchSets(sessionId: id)) ?? []
    }
}
