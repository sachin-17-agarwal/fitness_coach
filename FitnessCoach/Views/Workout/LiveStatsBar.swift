import SwiftUI

struct LiveStatsBar: View {
    let tonnage: Double
    let setCount: Int
    let duration: TimeInterval

    var body: some View {
        HStack {
            statItem(icon: "scalemass", value: formatTonnage(tonnage), label: "Tonnage")
            Spacer()
            statItem(icon: "number", value: "\(setCount)", label: "Sets")
            Spacer()
            statItem(icon: "timer", value: formatDuration(duration), label: "Duration")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.cardBackground)
    }

    private func statItem(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(Color.recoveryGreen)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundColor(.white)
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
    }

    private func formatTonnage(_ t: Double) -> String {
        if t >= 1000 {
            return String(format: "%.1fT", t / 1000)
        }
        return String(format: "%.0f kg", t)
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
