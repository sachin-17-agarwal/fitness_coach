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
                Color.background.ignoresSafeArea()

                VStack(spacing: 0) {
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
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    briefingButton
                }
            }
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
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
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
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Gradients.cool)
                    .frame(width: 72, height: 72)
                    .blur(radius: 18)
                    .opacity(0.6)
                Circle()
                    .fill(Gradients.cool)
                    .frame(width: 64, height: 64)
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text("Ask your coach")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Programming questions, form cues,\nrecovery strategy — anything training-related.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
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
                        Text(prompt)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.surfaceRaised)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.cardBorder, lineWidth: 0.5)
                            )
                    }
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
                    .foregroundStyle(.white)
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
                    .fill(Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(inputFocused ? Color.recoveryGreen.opacity(0.5) : Color.cardBorder, lineWidth: 0.5)
            )

            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            Color.background
                .overlay(
                    Rectangle()
                        .fill(Color.cardBorder.opacity(0.5))
                        .frame(height: 0.5),
                    alignment: .top
                )
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
                .foregroundStyle(.black)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(canSend ? AnyShapeStyle(Gradients.recovery) : AnyShapeStyle(Color.surfaceRaised))
                )
        }
        .disabled(!canSend)
        .animation(Motion.snappy, value: canSend)
    }

    private var briefingButton: some View {
        Button {
            Haptic.medium()
            Task { await viewModel.sendMorningBriefing() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                Text("Briefing")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Gradients.cool)
            )
        }
        .disabled(viewModel.isLoading)
    }
}

// MARK: - Typing indicator

struct TypingIndicator: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CoachAvatar()

            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.textSecondary)
                        .frame(width: 6, height: 6)
                        .opacity(phase == i ? 1 : 0.35)
                        .scaleEffect(phase == i ? 1.1 : 1)
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
                .fill(Gradients.cool)
                .frame(width: 30, height: 30)
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

#Preview {
    CoachChatView()
}
