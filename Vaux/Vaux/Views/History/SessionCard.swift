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
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [accent.opacity(0.35), Color.line],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            Haptic.light()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isExpanded.toggle() }
            if isExpanded && sets.isEmpty {
                Task { await loadSets() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: sessionIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.type)
                    .font(.uiStrong)
                    .foregroundStyle(Color.fg0)
                Text(prettyDate(session.date))
                    .font(.eyebrowSmall)
                    .kerning(1.0)
                    .foregroundStyle(Color.fg2)
            }

            Spacer()

            if let tonnage = session.tonnageKg, tonnage > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(tonnage.weightString)
                        .font(.numSM)
                        .foregroundStyle(Color.fg0)
                    Text("TONNAGE")
                        .font(.eyebrowSmall)
                        .kerning(1.0)
                        .foregroundStyle(Color.fg2)
                }
            }

            statusBadge(session.status)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.fg2)
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
                        .font(.system(size: 12, weight: .semibold))
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
                .font(.eyebrowSmall)
                .foregroundStyle(Color.fg2)
                .frame(width: 26, alignment: .leading)

            switch kind {
            case .cardio, .yoga:
                if let minutes = set.actualReps {
                    Text("\(minutes) min")
                        .font(.system(size: 13, weight: .medium, design: .monospaced).monospacedDigit())
                        .foregroundStyle(Color.fg0)
                }
                Text(kind == .yoga ? "YOGA" : "CARDIO")
                    .font(.eyebrowSmall)
                    .kerning(0.5)
                    .foregroundStyle(Color.forSession(kind == .yoga ? "Yoga" : "Cardio+Abs"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.ink3))
            case .strength:
                if let w = set.actualWeightKg, let r = set.actualReps {
                    Text("\(w.weightString) × \(r)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced).monospacedDigit())
                        .foregroundStyle(isWarmup ? Color.fg1 : Color.fg0)
                }

                if isWarmup {
                    Text("WARM-UP")
                        .font(.eyebrowSmall)
                        .kerning(0.5)
                        .foregroundStyle(Color.fg2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.ink3))
                }
            }

            Spacer()
            if let rpe = set.actualRpe {
                Text("RPE \(rpe.oneDecimal)")
                    .font(.eyebrowSmall)
                    .foregroundStyle(Color.fg1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.ink3))
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
        let color: Color = isCompleted ? .mint : .amber
        return Text(status.uppercased())
            .font(.eyebrowSmall)
            .kerning(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 0.5))
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
