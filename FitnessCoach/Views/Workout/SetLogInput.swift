import SwiftUI

struct SetLogInput: View {
    @Binding var weight: Double
    @Binding var reps: Int
    @Binding var rpe: Double
    let onLog: () -> Void
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text("Weight")
                        .font(.caption)
                        .foregroundColor(.gray)
                    HStack(spacing: 0) {
                        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { weight = max(0, weight - 2.5) } } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                        }
                        .pressableButton()
                        Text(weight.weightString)
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundColor(.white)
                            .frame(minWidth: 80)
                            .contentTransition(.numericText())
                        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { weight += 2.5 } } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                        }
                        .pressableButton()
                    }
                }

                VStack(spacing: 4) {
                    Text("Reps")
                        .font(.caption)
                        .foregroundColor(.gray)
                    HStack(spacing: 0) {
                        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { reps = max(1, reps - 1) } } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                        }
                        .pressableButton()
                        Text("\(reps)")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundColor(.white)
                            .frame(minWidth: 40)
                            .contentTransition(.numericText())
                        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { reps += 1 } } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                        }
                        .pressableButton()
                    }
                }
            }

            RPESlider(value: $rpe)

            Button(action: onLog) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("LOG SET")
                        .font(.headline.weight(.bold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.recoveryGreen)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(isLoading)
            .pressableButton()
        }
        .padding()
        .modifier(DarkCardStyle())
    }
}
