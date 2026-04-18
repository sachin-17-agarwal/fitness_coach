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
                        Button { weight = max(0, weight - 2.5) } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                        }
                        Text(weight.weightString)
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundColor(.white)
                            .frame(minWidth: 80)
                        Button { weight += 2.5 } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                        }
                    }
                }

                VStack(spacing: 4) {
                    Text("Reps")
                        .font(.caption)
                        .foregroundColor(.gray)
                    HStack(spacing: 0) {
                        Button { reps = max(1, reps - 1) } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                        }
                        Text("\(reps)")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundColor(.white)
                            .frame(minWidth: 40)
                        Button { reps += 1 } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                        }
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
        }
        .padding()
        .modifier(DarkCardStyle())
    }
}
