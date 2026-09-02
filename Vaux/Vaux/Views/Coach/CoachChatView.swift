// CoachChatView.swift
// Vaux
//
// The coach conversation as an editorial transcript, not a messenger: speakers
// are labelled with eyebrows and set as full-width text, plans render as
// ledger rows, and the header carries what the coach is looking at today.

import SwiftUI
import Combine

struct CoachChatView: View {
    @State private var viewModel = ChatViewModel()
    /// "Ask the coach about this" from other tabs lands here.
    private let handoff = ChatHandoff.shared
    @FocusState private var inputFocused: Bool
    /// "Start session →" on a plan card switches to the Train tab.
    var switchToTrainTab: (() -> Void)? = nil

    private let suggestions: [String] = [
        "Today's briefing",
        "How's my recovery?",
        "Train hard today?",
        "Plan my deload week"
    ]

    var body: some View {
        ZStack {
            Color.ink0.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if viewModel.messages.isEmpty && !viewModel.isLoading {
                    emptyState
                } else {
                    transcript
                }

                // Kept available mid-conversation, not just on an empty screen.
                // Hidden while composing, where the row would sit between the
                // field and the keyboard, and while a reply is in flight.
                if !inputFocused && !viewModel.isLoading {
                    suggestionsRow
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }

                composer
            }
            .animation(Motion.smooth, value: inputFocused)
        }
        .onAppear { adoptHandoff() }
        .onChange(of: handoff.pendingPrompt) { _, _ in adoptHandoff() }
        .task {
            await viewModel.loadConversation()
            await viewModel.loadContext()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    GlowDot(color: .signal, size: 7)
                    EditorialEyebrow(text: "Coach · Online")
                }
                Spacer()
                Button {
                    Haptic.medium()
                    Task { await viewModel.sendMorningBriefing() }
                } label: {
                    Text("BRIEFING →")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(2.5)
                        .foregroundStyle(Color.signal)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)
                .accessibilityLabel("Request morning briefing")
            }
            .frame(height: 44)

            HStack {
                EditorialEyebrow(text: viewModel.contextLine, color: Editorial.muted, size: 9.5, kerning: 1.8)
                Spacer()
                if let readiness = viewModel.readinessLabel {
                    EditorialEyebrow(text: readiness, color: .mint, size: 9.5, kerning: 1.8)
                }
            }
            .padding(.top, 4)

            Rectangle().fill(Color.line).frame(height: 1)
                .padding(.top, 12)
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 4)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    dayDivider("Today")

                    ForEach(Array(viewModel.messages.enumerated()), id: \.offset) { index, msg in
                        TranscriptTurn(message: msg, onStartSession: switchToTrainTab)
                            .id(index)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }

                    if viewModel.isLoading {
                        TypingIndicator()
                            .id("loading")
                    }

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.ember)
                            .padding(.top, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, Editorial.gutter)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) {
                withAnimation(Motion.smooth) {
                    proxy.scrollTo(viewModel.messages.count - 1, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.isLoading) { _, loading in
                if loading {
                    withAnimation(Motion.smooth) {
                        proxy.scrollTo("loading", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func dayDivider(_ label: String) -> some View {
        HStack(spacing: 12) {
            EditorialEyebrow(text: label, color: Editorial.muted, size: 9.5, kerning: 2.5)
            Rectangle().fill(Color.line).frame(height: 1)
        }
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            VauxLogo(size: 34, color: .signal)
                .shadow(color: Color.signal.opacity(0.5), radius: 12)
            Text("ASK YOUR COACH")
                .font(.display(34))
                .foregroundStyle(Color.fg0)
            EditorialEyebrow(text: "Programming · Form · Recovery", color: Editorial.muted, size: 10, kerning: 2.2)
            Spacer()
        }
        .padding(.horizontal, Editorial.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Places a question handed over from another tab into the composer.
    /// The athlete reviews and sends it; it is never sent automatically.
    private func adoptHandoff() {
        guard let prompt = handoff.consume(), !prompt.isEmpty else { return }
        viewModel.inputText = prompt
    }

    // MARK: - Suggestion chips

    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { prompt in
                    Button {
                        Haptic.selection()
                        viewModel.inputText = prompt
                        Task { await viewModel.sendMessage() }
                    } label: {
                        Text(prompt)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.fg1)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .overlay(Capsule().stroke(Color.line, lineWidth: 1))
                            .frame(minHeight: 44)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Sends this question to your coach")
                }
            }
            .padding(.horizontal, Editorial.gutter)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Message your coach…", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Color.fg0)
                    .focused($inputFocused)
                    .lineLimit(1...5)
                    .padding(.vertical, 14)
                    .padding(.leading, 16)

                if !viewModel.inputText.isEmpty {
                    Button {
                        viewModel.inputText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.fg3)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("Clear message")
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.ink2))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(inputFocused ? Color.signal.opacity(0.5) : Color.line, lineWidth: 1)
            )
            .animation(Motion.snappy, value: inputFocused)

            sendButton
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var sendButton: some View {
        let canSend = !viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty && !viewModel.isLoading
        return Button {
            Haptic.light()
            Task { await viewModel.sendMessage() }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(canSend ? Color.signalInk : Color.fg3)
                .frame(width: 48, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(canSend ? Color.signal : Color.ink3)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(!canSend)
        .buttonStyle(PressScaleStyle(scale: 0.92))
        .animation(Motion.snappy, value: canSend)
        .accessibilityLabel("Send")
    }
}

// MARK: - Typing indicator

struct TypingIndicator: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialEyebrow(text: "Coach", color: .mint, size: 10, kerning: 2.5)
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.mint)
                        .frame(width: 6, height: 6)
                        .opacity(phase == i ? 1 : 0.3)
                        .offset(y: phase == i ? -3 : 0)
                }
            }
        }
        .padding(.top, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                phase = (phase + 1) % 3
            }
        }
        .accessibilityLabel("Coach is typing")
    }
}

#Preview {
    CoachChatView()
}
