// CoachChatView.swift
// Vaux
//
// Chat UI with avatar bubbles, suggested prompt chips, typing indicator,
// and markdown-rendered coach responses.

import SwiftUI
import Combine

struct CoachChatView: View {
    @State private var viewModel = ChatViewModel()
    @FocusState private var inputFocused: Bool

    private let suggestions: [String] = [
        "Give me today's briefing",
        "How's my recovery looking?",
        "Should I train hard today?",
        "Plan my deload week"
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                TechBackground(accent: .signal)

                VStack(spacing: 0) {
                    ScreenHeader(
                        eyebrow: "Vaux Coach · Online",
                        title: "Coach",
                        showsLiveDot: true,
                        accessory: AnyView(briefingButton)
                    )
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                    if viewModel.messages.isEmpty && !viewModel.isLoading {
                        emptyState
                    } else {
                        messageList
                    }

                    if viewModel.messages.isEmpty {
                        suggestionsRow
                            .padding(.horizontal, 14)
                            .padding(.bottom, 6)
                    }

                    inputBar
                }
            }
            .navigationBarHidden(true)
            .task { await viewModel.loadConversation() }
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(viewModel.messages.enumerated()), id: \.offset) { index, msg in
                        MessageBubble(message: msg)
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
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(error)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Color.ember)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.ember.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.ember.opacity(0.22), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.signal.opacity(0.10), lineWidth: 1)
                    .frame(width: 132, height: 132)
                Circle()
                    .stroke(Color.signal.opacity(0.20), lineWidth: 1)
                    .frame(width: 96, height: 96)
                Circle()
                    .fill(Color.signal.opacity(0.06))
                    .frame(width: 96, height: 96)
                VauxLogo(size: 40, color: .signal)
                    .shadow(color: Color.signal.opacity(0.6), radius: 14)
            }

            VStack(spacing: 8) {
                Text("Ask your coach")
                    .font(.serifMD)
                    .foregroundStyle(Color.fg0)
                Text("PROGRAMMING · FORM · RECOVERY")
                    .font(.eyebrowSmall)
                    .kerning(1.6)
                    .foregroundStyle(Color.fg2)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
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
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.signal)
                            Text(prompt)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.fg1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.ink2.opacity(0.94))
                        )
                        .overlay(
                            Capsule()
                                .stroke(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.08), Color.line2],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message your coach…", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.fg0)
                    .focused($inputFocused)
                    .lineLimit(1...5)
                    .padding(.vertical, 10)
                    .padding(.leading, 14)

                if !viewModel.inputText.isEmpty {
                    Button {
                        viewModel.inputText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.textTertiary)
                    }
                    .padding(.trailing, 6)
                    .padding(.bottom, 10)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.ink2.opacity(0.9))
                    .background(
                        .ultraThinMaterial.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        inputFocused ? Color.signal.opacity(0.40) : Color.line,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: inputFocused ? Color.signal.opacity(0.12) : .clear,
                radius: 12
            )
            .animation(Motion.snappy, value: inputFocused)

            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            Color.ink0.opacity(0.85)
                .background(.ultraThinMaterial.opacity(0.4))
                .overlay(
                    Rectangle()
                        .fill(Color.line.opacity(0.6))
                        .frame(height: 1),
                    alignment: .top
                )
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var sendButton: some View {
        let canSend = !viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty && !viewModel.isLoading
        return Button {
            Haptic.light()
            Task { await viewModel.sendMessage() }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(canSend ? Color.signalInk : Color.fg2)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(canSend ? Color.signal : Color.ink3)
                )
                .shadow(color: canSend ? Color.signal.opacity(0.40) : .clear, radius: 10, x: 0, y: 4)
        }
        .disabled(!canSend)
        .buttonStyle(PressScaleStyle(scale: 0.92))
        .animation(Motion.snappy, value: canSend)
    }

    private var briefingButton: some View {
        Button {
            Haptic.medium()
            Task { await viewModel.sendMorningBriefing() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                Text("BRIEFING")
                    .font(.eyebrowSmall)
                    .kerning(1.2)
            }
            .foregroundStyle(Color.signal)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.signal.opacity(0.08)))
            .overlay(Capsule().stroke(Color.signal.opacity(0.22), lineWidth: 1))
        }
        .disabled(viewModel.isLoading)
    }
}

// MARK: - Typing indicator

struct TypingIndicator: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CoachAvatar()

            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.signal)
                        .frame(width: 7, height: 7)
                        .opacity(phase == i ? 1 : 0.3)
                        .offset(y: phase == i ? -4 : 0)
                        .scaleEffect(phase == i ? 1.15 : 0.85)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.cardBorder, lineWidth: 0.5)
            )

            Spacer(minLength: 40)
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                phase = (phase + 1) % 3
            }
        }
    }
}

// MARK: - Coach avatar

struct CoachAvatar: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.ink3)
            Circle()
                .stroke(Color.line2, lineWidth: 1)
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.signal)
        }
        .frame(width: 30, height: 30)
    }
}

#Preview {
    CoachChatView()
}
