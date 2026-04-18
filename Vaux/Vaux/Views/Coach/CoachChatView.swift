import SwiftUI

struct CoachChatView: View {
    @State private var viewModel = ChatViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(Array(viewModel.messages.enumerated()), id: \.offset) { index, msg in
                                MessageBubble(message: msg)
                                    .id(index)
                            }

                            if viewModel.isLoading {
                                HStack {
                                    ProgressView()
                                        .tint(.gray)
                                    Text("Coach is thinking...")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    Spacer()
                                }
                                .padding(.horizontal)
                                .id("loading")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.messages.count) {
                        withAnimation {
                            proxy.scrollTo(viewModel.messages.count - 1, anchor: .bottom)
                        }
                    }
                }

                Divider().background(Color.cardBorder)

                HStack(spacing: 12) {
                    TextField("Message your coach...", text: $viewModel.inputText)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 20))

                    Button {
                        Task { await viewModel.sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor(viewModel.inputText.isEmpty ? .gray : Color.recoveryGreen)
                    }
                    .disabled(viewModel.inputText.isEmpty || viewModel.isLoading)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.background)
            }
            .background(Color.background)
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Briefing") {
                        Task { await viewModel.sendMorningBriefing() }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Color.recoveryGreen)
                    .disabled(viewModel.isLoading)
                }
            }
            .task { await viewModel.loadConversation() }
        }
    }
}
