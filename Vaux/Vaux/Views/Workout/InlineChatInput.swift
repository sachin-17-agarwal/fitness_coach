// InlineChatInput.swift
// Vaux
//
// Talking to the coach mid-workout: a sheet in the Coach tab's own language.
// Header with the exercise and a way into the full conversation, the latest
// exchange as YOU / COACH turns, and a composer. Opened from the dock's round
// button; the coach's reply lands here and on the card's quote at once.

import SwiftUI
import Combine

struct WorkoutCoachSheet: View {
    @Binding var text: String
    let exercise: String
    /// The athlete's last question in this session, if any.
    let lastQuestion: String?
    /// The coach's latest note (the reply, once it lands).
    let coachNote: String?
    let isThinking: Bool
    let onSend: () -> Void
    var openInCoach: (() -> Void)? = nil

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                EditorialEyebrow(text: "Coach · \(exercise)")
                Spacer()
                if let openInCoach {
                    Button {
                        Haptic.light()
                        openInCoach()
                    } label: {
                        Text("OPEN IN COACH →")
                            .font(.system(size: 9.5, weight: .bold))
                            .kerning(1.8)
                            .foregroundStyle(Color.signal)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the full conversation in the Coach tab")
                }
            }
            .frame(height: 44)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let lastQuestion, !lastQuestion.isEmpty {
                        turn(who: "You", color: .signal, text: lastQuestion, ink: .bone)
                    }
                    if isThinking {
                        VStack(alignment: .leading, spacing: 12) {
                            EditorialEyebrow(text: "Coach", color: .mint, size: 10, kerning: 2.5)
                            CoachTypingDots()
                        }
                        .padding(.top, 18)
                    } else if let coachNote, !coachNote.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            EditorialEyebrow(text: "Coach", color: .mint, size: 10, kerning: 2.5)
                            MarkdownText(content: coachNote)
                                .font(.system(size: 14))
                                .lineSpacing(3)
                                .foregroundStyle(Color.fg0)
                        }
                        .padding(.top, 18)
                    } else if lastQuestion == nil {
                        EditorialEyebrow(text: "Ask about this set, a swap, or how it felt", color: Editorial.muted, size: 9.5, kerning: 1.8)
                            .padding(.top, 18)
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)

            HStack(spacing: 10) {
                TextField("Reply…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .lineLimit(1...4)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Color.fg0)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.ink2))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(focused ? Color.signal.opacity(0.5) : Color.line, lineWidth: 1))

                Button {
                    Haptic.light()
                    onSend()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend ? Color.signalInk : Color.fg3)
                        .frame(width: 46, height: 46)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(canSend ? Color.signal : Color.ink3))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressScaleStyle(scale: 0.92))
                .disabled(!canSend)
                .accessibilityLabel("Send to coach")
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 8)
        .background(Color.ink0)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focused = true }
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    private func turn(who: String, color: Color, text: String, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorialEyebrow(text: who, color: color, size: 10, kerning: 2.5)
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(ink)
        }
        .padding(.top, 18)
    }
}

/// Three mint dots while the coach composes.
struct CoachTypingDots: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.mint)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
                    .offset(y: phase == i ? -3 : 0)
            }
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.3)) { phase = (phase + 1) % 3 }
        }
        .accessibilityLabel("Coach is typing")
    }
}
