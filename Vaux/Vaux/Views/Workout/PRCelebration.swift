import SwiftUI

struct PRCelebration: View {
    let exercise: String
    let estimated1RM: Double
    @Binding var isShowing: Bool

    @State private var scale: CGFloat = 0.3
    @State private var opacity: Double = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.8)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("PR!")
                    .font(.system(size: 72, weight: .black))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.recoveryGreen, Color.recoveryYellow],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text(exercise)
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)

                Text("Est. 1RM: \(estimated1RM.weightString)")
                    .font(.title3.monospacedDigit())
                    .foregroundColor(Color.recoveryGreen)
            }
            .scaleEffect(scale)
            .opacity(opacity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                scale = 1.0
                opacity = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 0.3)) {
                    opacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isShowing = false
                }
            }
        }
    }
}
