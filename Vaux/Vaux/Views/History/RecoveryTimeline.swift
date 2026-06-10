// RecoveryTimeline.swift
// Vaux
//
// Expandable daily recovery cards (HRV, sleep, RHR, weight, optional extras).

import SwiftUI

struct RecoveryTimeline: View {
    let history: [Recovery]

    var body: some View {
        LazyVStack(spacing: 10) {
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
        VStack(alignment: .leading, spacing: 10) {
            header
            metricsRow
            if isExpanded {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 14, cornerRadius: 16)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptic.light()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isExpanded.toggle() }
        }
    }

    private var header: some View {
        HStack {
            Text(prettyDate(recovery.date))
                .font(.uiStrong)
                .foregroundStyle(Color.fg0)

            Spacer()

            if let hrv = recovery.hrv {
                HStack(spacing: 5) {
                    Circle()
                        .fill(hrvColor(hrv))
                        .frame(width: 7, height: 7)
                    Text("HRV \(Int(hrv))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
                        .foregroundStyle(Color.fg0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.ink3))
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.fg2)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 14) {
            if let sleep = recovery.sleepHours {
                miniMetric(icon: "moon.fill", value: String(format: "%.1fh", sleep), color: .accentBlue)
            }
            if let rhr = recovery.restingHr {
                miniMetric(icon: "heart.fill", value: "\(Int(rhr)) bpm", color: .recoveryRed)
            }
            if let weight = recovery.weightKg {
                miniMetric(icon: "scalemass.fill", value: String(format: "%.1f kg", weight), color: .accentAmber)
            }
            Spacer()
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().background(Color.cardBorder)
            if let steps = recovery.steps {
                detailRow("Steps", value: "\(steps)")
            }
            if let energy = recovery.activeEnergyKcal {
                detailRow("Active energy", value: "\(Int(energy)) kcal")
            }
            if let bf = recovery.bodyFatPct {
                detailRow("Body fat", value: "\(bf.oneDecimal)%")
            }
            if let vo2 = recovery.vo2Max {
                detailRow("VO₂ max", value: vo2.oneDecimal)
            }
            if let resp = recovery.respiratoryRate {
                detailRow("Respiratory rate", value: "\(resp.oneDecimal) br/min")
            }
            if let status = recovery.hrvStatus {
                detailRow("HRV status", value: status)
            }
        }
    }

    private func miniMetric(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
                .foregroundStyle(Color.fg1)
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.fg2)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced).monospacedDigit())
                .foregroundStyle(Color.fg0)
        }
    }

    private func prettyDate(_ dateString: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: dateString) else { return dateString }
        let out = DateFormatter()
        out.dateFormat = "EEE, MMM d"
        return out.string(from: date)
    }

    private func hrvColor(_ hrv: Double) -> Color {
        if hrv >= 50 { return .recoveryGreen }
        if hrv >= 35 { return .recoveryYellow }
        return .recoveryRed
    }
}
