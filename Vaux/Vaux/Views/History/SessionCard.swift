// SessionCard.swift
// Vaux
//
// Collapsible workout session card — status badge, tonnage, and grouped sets.

import SwiftUI

struct SessionCard: View {
    let session: WorkoutSession
    @State private var sets: [WorkoutSet] = []
    @State private var isExpanded = false

    private let workoutService = WorkoutService()

    private var accent: Color { Color.forSession(session.type) }

    private var sessionIcon: String {
        switch session.type {
        case "Pull": return "arrow.down.to.line"
        case "Push": return "dumbbell.fill"
        case "Legs": return "figure.strengthtraining.functional"
        case "Cardio+Abs": return "heart.circle.fill"
        case "Yoga": return "figure.mind.and.body"
        default: return "figure.strengthtraining.traditional"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isExpanded {
                if sets.isEmpty {
                    HStack {
                        ProgressView().tint(Color.textSecondary).scaleEffect(0.8)
                        Text("Loading sets…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textTertiary)
                    }
                    .padding(.top, 4)
                } else {
                    setsList
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 14, cornerRadius: 16)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptic.light()
            withAnimation(Motion.smooth) { isExpanded.toggle() }
            if isExpanded && sets.isEmpty {
                Task { await loadSets() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Gradients.forSession(session.type))
                    .frame(width: 38, height: 38)
                Image(systemName: sessionIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.type)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(prettyDate(session.date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            if let tonnage = session.tonnageKg, tonnage > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(tonnage.weightString)
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("tonnage")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.textTertiary)
                }
            }

            statusBadge(session.status)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
    }

    private var setsList: some View {
        // Group case-insensitively so "Leg Press" and "Leg press" collapse
        // into one block. Keep the first-seen display form (and prefer a
        // non-warmup label when one exists) to avoid an all-lowercase header.
        var order: [String] = []
        var display: [String: String] = [:]
        var buckets: [String: [WorkoutSet]] = [:]
        for set in sets {
            let key = set.exercise.lowercased()
            if buckets[key] == nil {
                order.append(key)
                display[key] = set.exercise
                buckets[key] = []
            } else if set.isWarmup != true, display[key]?.first?.isLowercase == true {
                display[key] = set.exercise
            }
            buckets[key]?.append(set)
        }

        return VStack(alignment: .leading, spacing: 12) {
            Divider().background(Color.cardBorder)

            ForEach(order, id: \.self) { key in
                VStack(alignment: .leading, spacing: 6) {
                    Text(display[key] ?? key.capitalized)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array((buckets[key] ?? []).enumerated()), id: \.offset) { _, s in
                            setRow(s)
                        }
                    }
                }
            }
        }
    }

    private func setRow(_ set: WorkoutSet) -> some View {
        let isWarmup = set.isWarmup == true
        let kind = entryKind(set)
        return HStack(spacing: 10) {
            Text("#\(set.setNumber)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.textTertiary)
                .frame(width: 26, alignment: .leading)

            switch kind {
            case .cardio, .yoga:
                if let minutes = set.actualReps {
                    Text("\(minutes) min")
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
                Text(kind == .yoga ? "YOGA" : "CARDIO")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .kerning(0.5)
                    .foregroundStyle(Color.forSession(kind == .yoga ? "Yoga" : "Cardio+Abs"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.surface))
            case .strength:
                if let w = set.actualWeightKg, let r = set.actualReps {
                    Text("\(w.weightString) × \(r)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(isWarmup ? Color.textSecondary : .white)
                }

                if isWarmup {
                    Text("WARM-UP")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .kerning(0.5)
                        .foregroundStyle(Color.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.surface))
                }
            }

            Spacer()
            if let rpe = set.actualRpe {
                Text("RPE \(rpe.oneDecimal)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.surface))
            }
        }
    }

    private enum EntryKind { case strength, cardio, yoga }

    /// Cardio/yoga entries are tagged via the `notes` column on write
    /// (see `CardioYogaLogView`). Treat anything else as a strength set so
    /// legacy rows keep rendering as "weight × reps".
    private func entryKind(_ set: WorkoutSet) -> EntryKind {
        let note = (set.notes ?? "").lowercased()
        if note.hasPrefix("yoga") || note.contains(" yoga") { return .yoga }
        if note.hasPrefix("cardio") || note.contains(" cardio") { return .cardio }
        return .strength
    }

    private func statusBadge(_ status: String) -> some View {
        let isCompleted = status == "completed"
        let color: Color = isCompleted ? .recoveryGreen : .recoveryYellow
        return Text(status.capitalized)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .kerning(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(color.opacity(0.15))
            )
    }

    private func prettyDate(_ dateString: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: dateString) else { return dateString }
        let out = DateFormatter()
        out.dateFormat = "EEE, MMM d"
        return out.string(from: date)
    }

    private func loadSets() async {
        guard let id = session.id else { return }
        sets = (try? await workoutService.fetchSets(sessionId: id)) ?? []
    }
}
