// InlineChatInput.swift
// Vaux
//
// Collapsible chat input for mid-workout questions.

import SwiftUI

struct InlineChatInput: View {
    @Binding var text: String
    @Binding var isExpanded: Bool
    let onSend: () -> Void
    let isLoading: Bool

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button {
                Haptic.light()
                withAnimation(Motion.smooth) {
                    isExpanded.toggle()
                }
                if isExpanded {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        focused = true
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentTeal)
                    Text("Ask coach")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            if isExpanded {
                HStack(spacing: 10) {
                    TextField("e.g. machine is taken, any subs?", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .lineLimit(1...3)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.surface)
                        )

                    Button {
                        Haptic.light()
                        onSend()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(text.isEmpty ? AnyShapeStyle(Color.surfaceRaised) : AnyShapeStyle(Gradients.cool))
                            )
                    }
                    .disabled(text.isEmpty || isLoading)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            Color.surface
                .overlay(
                    Rectangle()
                        .fill(Color.cardBorder.opacity(0.6))
                        .frame(height: 0.5),
                    alignment: .top
                )
        )
    }
}
