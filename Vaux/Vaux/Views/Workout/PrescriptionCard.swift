import SwiftUI

struct PrescriptionCard: View {
    let prescription: ExercisePrescription

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prescription.exerciseName)
                .font(.title2.weight(.bold))
                .foregroundColor(.white)

            if !prescription.warmupSets.isEmpty {
                setSection(title: "Warm-up", sets: prescription.warmupSets.map { (w, r) in
                    "\(formatWeight(w)) x\(r)"
                }, color: .gray)
            }

            if !prescription.workingSets.isEmpty {
                setSection(title: "Working Set", sets: prescription.workingSets.map { (w, r, rpe) in
                    var s = "\(formatWeight(w)) x\(r)"
                    if let rpe { s += " @RPE\(formatRPE(rpe))" }
                    return s
                }, color: Color.recoveryGreen)
            }

            if !prescription.backoffSets.isEmpty {
                setSection(title: "Back-off", sets: prescription.backoffSets.map { (w, r, rpe) in
                    var s = "\(formatWeight(w)) x\(r)"
                    if let rpe { s += " @RPE\(formatRPE(rpe))" }
                    return s
                }, color: Color.recoveryYellow)
            }

            if let cue = prescription.formCue, !cue.isEmpty {
                Text(cue)
                    .font(.callout.italic())
                    .foregroundColor(.gray)
            }

            if let rest = prescription.restSeconds {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text("Rest: \(rest / 60):\(String(format: "%02d", rest % 60))")
                }
                .font(.caption)
                .foregroundColor(.gray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .modifier(DarkCardStyle())
    }

    private func setSection(title: String, sets: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(color)
            ForEach(sets, id: \.self) { s in
                Text(s)
                    .font(.body.monospacedDigit())
                    .foregroundColor(.white)
            }
        }
    }

    private func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(w))kg" : String(format: "%.1fkg", w)
    }

    private func formatRPE(_ r: Double) -> String {
        r.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(r))" : String(format: "%.1f", r)
    }
}
