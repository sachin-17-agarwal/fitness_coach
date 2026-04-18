import SwiftUI

struct InlineChatInput: View {
    @Binding var text: String
    @Binding var isExpanded: Bool
    let onSend: () -> Void
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "message")
                    Text("Ask coach")
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                }
                .font(.caption.weight(.medium))
                .foregroundColor(.gray)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            if isExpanded {
                HStack(spacing: 10) {
                    TextField("e.g. should I go heavier?", text: $text)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(Color.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundColor(text.isEmpty ? .gray : Color.recoveryGreen)
                    }
                    .disabled(text.isEmpty || isLoading)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.background)
    }
}
