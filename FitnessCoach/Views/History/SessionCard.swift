import SwiftUI

struct SessionCard: View {
    let session: WorkoutSession
    @State private var sets: [WorkoutSet] = []
    @State private var isExpanded = false

    private let workoutService = WorkoutService()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.type)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text(formattedDate(session.date))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.textSecondary)
                }

                Spacer()

                if let tonnage = session.tonnageKg {
                    Text(tonnage.weightString)
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundColor(Color.recoveryGreen)
                }

                statusBadge(session.status)

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.gray)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
            }

            if isExpanded && !sets.isEmpty {
                Divider().background(Color.cardBorder)

                let grouped = Dictionary(grouping: sets, by: \.exercise)
                ForEach(grouped.keys.sorted(), id: \.self) { exercise in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(exercise)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Color.recoveryGreen)
                            .padding(.top, 4)

                        ForEach(grouped[exercise] ?? [], id: \.setNumber) { s in
                            HStack {
                                Text("Set \(s.setNumber)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                    .frame(width: 44, alignment: .leading)
                                if let w = s.actualWeightKg, let r = s.actualReps {
                                    Text("\(w.weightString) \u{00D7} \(r)")
                                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                                        .foregroundColor(.white)
                                }
                                Spacer()
                                if let rpe = s.actualRpe {
                                    Text("@\(rpe.oneDecimal)")
                                        .font(.system(size: 12).monospacedDigit())
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                }
            }
        }
        .darkCard()
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
            if isExpanded && sets.isEmpty {
                Task { await loadSets() }
            }
        }
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status.capitalized)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status == "completed" ? Color.recoveryGreen.opacity(0.12) : Color.recoveryYellow.opacity(0.12))
            .foregroundColor(status == "completed" ? Color.recoveryGreen : Color.recoveryYellow)
            .clipShape(Capsule())
    }

    private func formattedDate(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return dateStr }

        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard month >= 1, month <= 12 else { return dateStr }
        return "\(months[month]) \(day)"
    }

    private func loadSets() async {
        guard let id = session.id else { return }
        sets = (try? await workoutService.fetchSets(sessionId: id)) ?? []
    }
}
