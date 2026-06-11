// RestTimer.swift
// Vaux
//
// Full-screen rest countdown ring with skip + add-15s controls.
//
// The countdown is driven by an absolute `endDate`, not a per-second
// integer tick. A `TimelineView(.animation)` re-renders the ring and
// readout from the real elapsed time every frame, so the sweep is smooth
// and the displayed seconds stay locked to wall-clock — even if the run
// loop is briefly busy. Completion fires once from a single `.task` that
// sleeps until the deadline.

import SwiftUI

struct RestTimer: View {
    let totalSeconds: Int
    @Binding var endDate: Date?
    @Binding var isActive: Bool
    let onSkip: () -> Void

    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            Color.ink0.opacity(0.88)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                HStack(spacing: 8) {
                    GlowDot(color: .mint, size: 5)
                    Text("REST")
                        .font(.eyebrow)
                        .kerning(2.5)
                        .foregroundStyle(Color.fg2)
                }

                TimelineView(.animation) { context in
                    let remaining = remaining(at: context.date)
                    ringView(remaining: remaining)
                }
                .frame(width: 220, height: 220)
                .scaleEffect(pulse ? 1.02 : 1.0)
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)

                controls
            }
        }
        .onAppear { pulse = true }
        .task(id: endDate) {
            guard let endDate else { return }
            let delay = endDate.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            Haptic.warning()
            isActive = false
        }
    }

    // MARK: - Ring

    private func ringView(remaining: Double) -> some View {
        let color = ringColor(remaining)
        return ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: 10)

            Circle()
                .trim(from: 0, to: progress(remaining))
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.6), radius: 14, x: 0, y: 0)

            VStack(spacing: 4) {
                Text(timeString(remaining))
                    .font(.system(size: 56, weight: .light, design: .serif).monospacedDigit())
                    .foregroundStyle(Color.fg0)
                Text(statusText(remaining))
                    .font(.eyebrowSmall)
                    .kerning(1.4)
                    .foregroundStyle(color)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                Haptic.light()
                endDate = (endDate ?? Date()).addingTimeInterval(15)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("+15s")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.fg0)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.ink3))
                .overlay(Capsule().stroke(Color.line2, lineWidth: 1))
            }
            .buttonStyle(PressScaleStyle())

            Button {
                Haptic.medium()
                onSkip()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "forward.fill")
                    Text("Skip")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.signalInk)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.signal))
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    // MARK: - Derived values

    private func remaining(at date: Date) -> Double {
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(date))
    }

    private func progress(_ remaining: Double) -> Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1, max(0, remaining / Double(totalSeconds)))
    }

    private func ringColor(_ remaining: Double) -> Color {
        if remaining <= 10 { return .ember }
        if remaining <= 30 { return .amber }
        return .mint
    }

    private func statusText(_ remaining: Double) -> String {
        if remaining <= 10 { return "ALMOST" }
        if remaining <= 30 { return "GET READY" }
        return "RECOVER"
    }

    private func timeString(_ remaining: Double) -> String {
        // Round up so the readout shows "1:00" for the final whole second
        // rather than flicking to "0:00" while time is still left.
        let secs = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}
