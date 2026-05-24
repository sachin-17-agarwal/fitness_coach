import SwiftUI

struct RecoveryTimeline: View {
    let history: [Recovery]

    var body: some View {
        LazyVStack(spacing: 10) {
            ForEach(Array(history.enumerated()), id: \.element.date) { index, day in
                RecoveryDayCard(recovery: day)
                    .staggeredAppearance(index: index)
            }
        }
    }
}

struct RecoveryDayCard: View {
    let recovery: Recovery
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(formattedDate(recovery.date))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                if let hrv = recovery.hrv {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(hrvColor(hrv))
                            .frame(width: 8, height: 8)
                        Text("HRV \(Int(hrv))")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundColor(.white)
                    }
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.gray)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
            }

            HStack(spacing: 20) {
                if let sleep = recovery.sleepHours {
                    miniMetric(icon: "moon.fill", value: "\(sleep.oneDecimal)h", color: Color(hex: "6B9DFF"))
                }
                if let rhr = recovery.restingHr {
                    miniMetric(icon: "heart.fill", value: "\(Int(rhr)) bpm", color: .recoveryRed)
                }
                if let weight = recovery.weightKg {
                    miniMetric(icon: "scalemass.fill", value: "\(weight.oneDecimal) kg", color: .recoveryYellow)
                }
            }

            if isExpanded {
                Divider().background(Color.cardBorder)

                VStack(spacing: 6) {
                    if let steps = recovery.steps {
                        detailRow("Steps", value: formatNumber(steps))
                    }
                    if let energy = recovery.activeEnergyKcal {
                        detailRow("Active Energy", value: "\(Int(energy)) kcal")
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .darkCard()
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isExpanded.toggle() }
        }
    }

    private func miniMetric(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(Color.textSecondary)
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
        }
    }

    private func formattedDate(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let year = Int(parts[0]) else { return dateStr }

        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard month >= 1, month <= 12 else { return dateStr }

        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let weekday: String
        if let date = formatter.date(from: dateStr) {
            let cal = Calendar.current
            let idx = cal.component(.weekday, from: date) - 1
            weekday = weekdays[idx]
        } else {
            weekday = ""
        }

        return "\(weekday), \(months[month]) \(day)"
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func hrvColor(_ hrv: Double) -> Color {
        if hrv >= 50 { return Color.recoveryGreen }
        if hrv >= 35 { return Color.recoveryYellow }
        return Color.recoveryRed
    }
}
