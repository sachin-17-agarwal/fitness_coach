// StepperButton.swift
// Vaux
//
// The ± control behind every numeric field in the logger.
//
// Two things the plain Button it replaces got wrong. It drew at 32×32, under
// the 44pt minimum, in the one part of the app operated mid-set with chalk or
// sweat on your hands — so the visual circle stays 32pt to keep the card's
// proportions, and the touch area is padded out to 44pt around it. And it
// fired once per tap, which made a 0 → 60 kg change twenty-four separate taps;
// holding now repeats, accelerating the way a system stepper does.

import SwiftUI

struct StepperButton: View {
    let systemName: String
    /// Spoken by VoiceOver, which cannot infer "increase weight" from a glyph.
    let accessibilityLabel: String
    let action: () -> Void

    /// Drawn diameter. The hit area is always at least 44pt regardless.
    var diameter: CGFloat = 32

    @State private var repeatTask: Task<Void, Never>?

    /// Held before the repeat begins, so a normal tap never triggers one.
    private let holdDelay: Duration = .milliseconds(400)
    /// Starting gap between repeats, shrinking toward `minimumInterval` so long
    /// holds cover ground without making small adjustments hard to land.
    private let initialInterval: Duration = .milliseconds(180)
    private let minimumInterval: Duration = .milliseconds(45)

    /// Set once a hold has started firing, so the release doesn't add one more
    /// on top of the repeats. A `Button`'s action runs on touch-up, which after
    /// a two-second hold would otherwise land as an unwanted extra increment.
    @State private var didRepeat = false

    var body: some View {
        // A real Button rather than tap and long-press gestures stacked on a
        // shape: those two conflict (a zero-duration long press pre-empts the
        // tap), and Button brings correct hit-testing, disabled handling, and
        // VoiceOver activation with it. The style reports the press state that
        // drives the repeat.
        Button {
            guard !didRepeat else { return }
            Haptic.soft()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.fg0)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.ink1))
                // Grows the touch target past the drawn circle without moving
                // it: `contentShape` makes the padded frame the hit region.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressReportingStyle { isPressing in
            if isPressing {
                didRepeat = false
                startRepeating()
            } else {
                stopRepeating()
            }
        })
        .accessibilityLabel(accessibilityLabel)
    }

    private func startRepeating() {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            // The button's own action covers the single tap, so this waits out
            // the hold delay before contributing anything.
            try? await Task.sleep(for: holdDelay)
            guard !Task.isCancelled else { return }

            var interval = initialInterval
            while !Task.isCancelled {
                didRepeat = true
                Haptic.soft()
                action()
                try? await Task.sleep(for: interval)
                interval = max(minimumInterval, interval - .milliseconds(12))
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

/// Button style that forwards press state to the caller while keeping the
/// app's standard pressed-scale feedback.
private struct PressReportingStyle: ButtonStyle {
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChange(isPressed)
            }
    }
}
