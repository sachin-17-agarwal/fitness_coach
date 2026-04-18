import SwiftUI

struct RecoveryTimeline: View {
    let history: [Recovery]

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach(history, id: \.date) { day in
                RecoveryDayCard(recovery: day)
            }
        }
    }
}

struct RecoveryDayCard: View {
    let recovery: Recovery
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(recovery.date)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Spacer()
                if let hrv = recovery.hrv {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(hrvColor(hrv))
                            .frame(width: 8, height: 8)
                        Text("HRV \(hrv.oneDecimal)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white)
                    }
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            HStack(spacing: 16) {
                if let sleep = recovery.sleepHours {
                    miniMetric(icon: "moon.fill", value: sleep.oneDecimal, unit: "hrs")
                }
                if let rhr = recovery.restingHr {
                    miniMetric(icon: "heart.fill", value: rhr.oneDecimal, unit: "bpm")
                }
                if let weight = recovery.weightKg {
                    miniMetric(icon: "scalemass", value: weight.oneDecimal, unit: "kg")
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let steps = recovery.steps {
                        detailRow("Steps", value: "\(steps)")
                    }
                    if let energy = recovery.activeEnergyKcal {
                        detailRow("Active Energy", value: "\(energy.oneDecimal) kcal")
                    }
                    if let bf = recovery.bodyFatPct {
                        detailRow("Body Fat", value: "\(bf.oneDecimal)%")
                    }
                    if let vo2 = recovery.vo2Max {
                        detailRow("VO2 Max", value: vo2.oneDecimal)
                    }
                    if let status = recovery.hrvStatus {
                        detailRow("Status", value: status)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding()
        .modifier(DarkCardStyle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
    }

    private func miniMetric(icon: String, value: String, unit: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(.gray)
            Text("\(value) \(unit)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.gray)
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundColor(.white)
        }
    }

    private func hrvColor(_ hrv: Double) -> Color {
        if hrv >= 50 { return Color.recoveryGreen }
        if hrv >= 35 { return Color.recoveryYellow }
        return Color.recoveryRed
    }
}
