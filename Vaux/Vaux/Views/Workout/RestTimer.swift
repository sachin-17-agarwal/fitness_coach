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
    /// Extending has to go through the view model so the ring's total grows
    /// with the deadline; mutating `endDate` alone left the ring pinned full.
    var onExtend: (Int) -> Void = { _ in }
    /// The set this rest leads into, shown so the countdown doesn't hide
    /// the target it is counting down to.
    var nextSet: String?
    /// The coach's latest feedback. Rest is the only point in a session
    /// with time to actually read it, and it was previously hidden behind
    /// the full-screen timer.
    var coachNote: String?
    var isCoachThinking: Bool = false
    /// Composer state, bound to the same view-model fields the inline chat
    /// below the set list uses. Sharing them means a question asked during
    /// rest travels the identical path — and the reply lands in `coachNote`
    /// right above the composer.
    var chatText: Binding<String> = .constant("")
    var onSend: () -> Void = {}

    @State private var pulse: Bool = false
    @State private var showChat: Bool = false
    @FocusState private var chatFocused: Bool

    /// The ring gives up most of its size while composing — with the keyboard
    /// up there isn't room for both, and the thing being looked at is the
    /// coach's reply, not the countdown.
    private var ringScale: CGFloat { chatFocused ? 0.55 : 1.0 }

    var body: some View {
        ZStack {
            Color.ink0.opacity(0.88)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            // GeometryReader + minHeight keeps the old centred layout when
            // everything fits, and only starts scrolling once the keyboard
            // shrinks the container past the content. A bare ScrollView would
            // top-align the ring even with the keyboard down.
            GeometryReader { proxy in
                ScrollView {
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
                        // Scale visually but also give back the layout height,
                        // so the composer and note rise into the freed space
                        // instead of being pushed under the keyboard.
                        .scaleEffect(ringScale)
                        .frame(height: 220 * ringScale)

                        if let nextSet, !chatFocused { upNext(nextSet) }

                        if !chatFocused { controls }

                        coachNotePanel

                        chatBar
                    }
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    .animation(Motion.smooth, value: chatFocused)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .onAppear {
            pulse = true
            // The timer takes the screen over from the set logger, whose
            // weight field may still hold first responder. Its "Done" button
            // only clears that view's own @FocusState, which by then has
            // already been reset — so the button did nothing and the keyboard
            // sat there over the countdown. Resigning app-wide clears whatever
            // is actually focused, regardless of which view owns it.
            dismissKeyboard()
        }
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

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    // MARK: - Ring

    private func ringView(remaining: Double) -> some View {
        let color = ringColor(remaining)
        return ZStack {
            // Watch-dial tick marks — majors every 5 ticks
            ForEach(0..<60, id: \.self) { i in
                let isMajor = i % 5 == 0
                Rectangle()
                    .fill(Color.white.opacity(isMajor ? 0.22 : 0.08))
                    .frame(width: 1.5, height: isMajor ? 9 : 5)
                    .offset(y: -88)
                    .rotationEffect(.degrees(Double(i) * 6))
            }

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

    // MARK: - Up next

    /// Borderless on purpose. The previous version was a full-width bordered
    /// box that carried the same visual weight as the ring and fought it for
    /// attention; here the type hierarchy does the work — a quiet eyebrow for
    /// position, the exercise in the app's serif, and the numbers he actually
    /// acts on rendered large in mono.
    private func upNext(_ text: String) -> some View {
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        let exercise = parts.first ?? text
        // "Working set 2 of 3 · BW × 10 @ RPE 7" -> position, then the load.
        let detail = parts.count > 1 ? parts[1] : ""
        let split = detail.components(separatedBy: " · ")
        let position = split.count > 1 ? split[0] : ""
        let load = split.count > 1 ? split.dropFirst().joined(separator: " · ") : detail

        return VStack(spacing: 6) {
            Text(position.isEmpty ? "UP NEXT" : "UP NEXT · \(position.uppercased())")
                .font(.eyebrowSmall)
                .kerning(1.6)
                .foregroundStyle(Color.fg2)

            Text(exercise)
                .font(.serifSM)
                .foregroundStyle(Color.fg0)
                .multilineTextAlignment(.center)

            if !load.isEmpty {
                // A load line always arrives as "position · numbers". Without
                // the separator the detail is prose (the handoff message while
                // the coach writes the next block), which must not be rendered
                // in the big mono treatment reserved for weights.
                let isLoad = split.count > 1
                Text(load)
                    .font(isLoad ? .numMD : .system(size: 13))
                    .foregroundStyle(isLoad ? Color.mint : Color.fg2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Coach note

    /// Rest is the only stretch of a session with time to read. Capped and
    /// scrollable so a long note can't push the controls off screen.
    @ViewBuilder
    private var coachNotePanel: some View {
        if isCoachThinking {
            HStack(spacing: 8) {
                ProgressView().tint(Color.fg2).scaleEffect(0.7)
                Text("Coach is writing…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.fg2)
            }
            .padding(.top, 2)
        } else if let coachNote, !coachNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("COACH")
                    .font(.eyebrowSmall)
                    .kerning(1.6)
                    .foregroundStyle(Color.fg2)

                ScrollView(showsIndicators: false) {
                    Text(coachNote)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.fg0.opacity(0.92))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Tighter while composing so a long reply can't push the
                // field it's being answered in off the top of the screen.
                .frame(maxHeight: chatFocused ? 96 : 150)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.ink2.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.line, lineWidth: 1)
            )
            .padding(.horizontal, 22)
        }
    }

    // MARK: - Composer

    /// Asking something mid-rest previously meant skipping the timer to reach
    /// the inline chat underneath. Collapsed to a single row so it costs no
    /// attention until it's wanted.
    @ViewBuilder
    private var chatBar: some View {
        if showChat {
            HStack(spacing: 10) {
                TextField("Ask the coach…", text: chatText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($chatFocused)
                    .lineLimit(1...3)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.fg0)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.ink2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(chatFocused ? Color.signal.opacity(0.35) : Color.line,
                                    lineWidth: 1)
                    )

                Button {
                    Haptic.light()
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canSend ? Color.signalInk : Color.fg2)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canSend ? Color.signal : Color.ink3))
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 22)
        } else {
            Button {
                Haptic.light()
                showChat = true
                chatFocused = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Ask coach")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.fg1)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.ink3))
                .overlay(Capsule().stroke(Color.line2, lineWidth: 1))
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    private var canSend: Bool {
        !chatText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isCoachThinking
    }

    /// Drops the keyboard but keeps the composer open — the reply arrives in
    /// the note panel directly above, and a follow-up is usually one tap away.
    private func send() {
        guard canSend else { return }
        onSend()
        chatFocused = false
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                Haptic.light()
                onExtend(15)
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
