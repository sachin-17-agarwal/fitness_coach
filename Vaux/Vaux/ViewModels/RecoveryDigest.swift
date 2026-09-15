// RecoveryDigest.swift
// Vaux
//
// One card on Monday: last week's recovery in two or three sentences, from
// the same daily facts the Recovery tab draws, with no model call. The
// Recovery tab has the numbers; a weekly line is what changes behaviour —
// bedtime, a planned lighter day — and the third sentence checks the
// readiness taps against what the numbers said, which is the standing test
// of whether the read and the athlete agree.
//
// Every sentence is built from the log by rules written here, so the card
// never says anything the History tab could not also show.

import Foundation

struct RecoveryDigest: Equatable {
    /// "8 – 14 SEP"
    let rangeLabel: String
    let sentences: [String]

    // Shown on Monday and Tuesday for the Monday-to-Sunday week just ended.
    static let showOnWeekdays: Set<Int> = [2, 3]   // Calendar: Sunday = 1

    /// Nil outside Monday/Tuesday or when the week has no recovery rows.
    static func build(rows: [Recovery], today: Date = Date(), calendar cal: Calendar = .current) -> RecoveryDigest? {
        let weekday = cal.component(.weekday, from: today)
        guard showOnWeekdays.contains(weekday) else { return nil }
        let startOfToday = cal.startOfDay(for: today)
        guard let lastSunday = cal.date(byAdding: .day, value: -(weekday - 1), to: startOfToday),
              let monday = cal.date(byAdding: .day, value: -6, to: lastSunday) else { return nil }
        return build(rows: rows, weekEnding: lastSunday, weekStarting: monday, calendar: cal)
    }

    /// The window is explicit here so tests can pin it.
    static func build(rows: [Recovery], weekEnding sunday: Date, weekStarting monday: Date,
                      calendar cal: Calendar = .current) -> RecoveryDigest? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let byDate = Dictionary(rows.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })

        // Daily slots: 42 baseline days, then the week itself. Oldest first.
        var dates: [Date] = []
        for offset in stride(from: 6 + RecoveryInsightsViewModel.baselineDays, through: 0, by: -1) {
            if let d = cal.date(byAdding: .day, value: -offset, to: sunday) { dates.append(d) }
        }
        let keys = dates.map { f.string(from: $0) }
        let daily = keys.map { byDate[$0] }
        let week = Array(daily.suffix(7))
        let weekDates = Array(dates.suffix(7))
        guard week.contains(where: { $0 != nil }) else { return nil }

        var sentences: [String] = []

        // ── HRV against the baseline band ────────────────────────────────
        let hrvWeek = week.compactMap { $0?.hrv }
        if !hrvWeek.isEmpty {
            let avg = mean(hrvWeek)
            let basis = daily.dropLast(7).compactMap { $0?.hrv }.filter { $0 > 0 }
            if basis.count >= 5 {
                let logs = basis.map { Foundation.log($0) }
                let m = mean(logs), sd = max(stdDev(logs), 0.02)
                let band = exp(m - sd)...exp(m + sd)
                let inside = hrvWeek.filter { band.contains($0) }.count
                let below = hrvWeek.filter { $0 < band.lowerBound }.count
                let where_: String
                if inside >= hrvWeek.count - 1 { where_ = "inside your baseline band" }
                else if below > hrvWeek.count / 2 { where_ = "below your baseline band" }
                else if hrvWeek.filter({ $0 > band.upperBound }).count > hrvWeek.count / 2 { where_ = "above your baseline band" }
                else { where_ = "in and out of your baseline band" }
                sentences.append(String(format: "HRV averaged %.0f ms, %@ (%.0f–%.0f) on %d of %d mornings.",
                                        avg, where_, band.lowerBound, band.upperBound, inside, hrvWeek.count))
            } else {
                sentences.append(String(format: "HRV averaged %.0f ms over %d readings; the baseline band needs more history.",
                                        avg, hrvWeek.count))
            }
        }

        // ── Sleep and weight ─────────────────────────────────────────────
        var parts: [String] = []
        let nights: [(Date, Double)] = zip(weekDates, week).compactMap { d, r in
            guard let h = r?.sleepHours, h >= RecoveryInsightsViewModel.missingSleepBelow else { return nil }
            return (d, h)
        }
        if !nights.isEmpty {
            let short = nights.filter { $0.1 < RecoveryInsightsViewModel.shortNight }
            let debt = nights.reduce(0.0) { $0 + max(0, RecoveryInsightsViewModel.sleepNeed - $1.1) }
            let dayF = DateFormatter(); dayF.dateFormat = "EEE"; dayF.locale = Locale(identifier: "en_US_POSIX")
            if short.isEmpty {
                parts.append(String(format: "Every recorded night reached %g h", RecoveryInsightsViewModel.shortNight))
            } else {
                let names = short.map { dayF.string(from: $0.0) }.joined(separator: ", ")
                let debtText = clock(debt)
                parts.append("\(spelled(short.count)) short night\(short.count == 1 ? "" : "s") (\(names)) left you "
                             + "\(debtText) under your \(String(format: "%g", RecoveryInsightsViewModel.sleepNeed)) h need")
            }
        }
        let weightWeek = week.compactMap { $0?.weightKg }
        let weightPrior = daily.dropLast(7).suffix(7).compactMap { $0?.weightKg }
        if let latest = weightWeek.last {
            if !weightPrior.isEmpty {
                let delta = mean(weightWeek) - mean(weightPrior)
                if abs(delta) < 0.3 {
                    parts.append(String(format: "weight %.1f kg, flat", latest))
                } else {
                    parts.append(String(format: "weight %.1f kg, %@%.1f kg on the week", latest, delta < 0 ? "down " : "up ", abs(delta)))
                }
            } else {
                parts.append(String(format: "weight %.1f kg", latest))
            }
        }
        if !parts.isEmpty {
            var s = parts.joined(separator: "; ")
            s = s.prefix(1).uppercased() + s.dropFirst()
            sentences.append(s + ".")
        }

        // ── Readiness taps against the numbers ───────────────────────────
        // The tap is 1 (wrecked) to 5 (fresh); the numbers are the composite
        // score against the seven days before each morning, bucketed the way
        // the Home hero colours it. Agreement is the same bucket.
        var taps = 0, agreed = 0
        for (i, r) in daily.enumerated().suffix(7) {
            guard let r, let tap = r.readiness else { continue }
            let prior = daily[max(0, i - 7)..<i].compactMap { $0 }
            let hrvAvg = prior.compactMap(\.hrv).isEmpty ? nil : mean(prior.compactMap(\.hrv))
            let rhrAvg = prior.compactMap(\.restingHr).isEmpty ? nil : mean(prior.compactMap(\.restingHr))
            guard let score = r.compositeScore(hrv7DayAvg: hrvAvg, rhr7DayAvg: rhrAvg) else { continue }
            taps += 1
            let tapBucket = tap <= 2 ? 0 : (tap == 3 ? 1 : 2)
            let scoreBucket = score >= 75 ? 2 : (score >= 55 ? 1 : 0)
            if tapBucket == scoreBucket { agreed += 1 }
        }
        if taps > 0 {
            sentences.append("You rated yourself on \(spelled(taps).lowercased()) morning\(taps == 1 ? "" : "s"); "
                             + "the numbers agreed \(agreed == taps ? "every time" : "\(spelled(agreed).lowercased()) time\(agreed == 1 ? "" : "s")").")
        }

        guard !sentences.isEmpty else { return nil }
        let dF = DateFormatter(); dF.dateFormat = "d"; dF.locale = Locale(identifier: "en_US_POSIX")
        let mF = DateFormatter(); mF.dateFormat = "d MMM"; mF.locale = Locale(identifier: "en_US_POSIX")
        let sameMonth = cal.component(.month, from: monday) == cal.component(.month, from: sunday)
        let label = (sameMonth ? "\(dF.string(from: monday)) – \(mF.string(from: sunday))"
                               : "\(mF.string(from: monday)) – \(mF.string(from: sunday))").uppercased()
        return RecoveryDigest(rangeLabel: label, sentences: sentences)
    }

    // MARK: - Helpers

    private static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
    private static func stdDev(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = mean(xs)
        return sqrt(xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1))
    }
    private static func clock(_ hours: Double) -> String {
        let total = Int((hours * 60).rounded())
        return total < 60 ? "\(total) min" : String(format: "%dh%02d", total / 60, total % 60)
    }
    private static func spelled(_ n: Int) -> String {
        let words = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven"]
        return n < words.count ? words[n] : "\(n)"
    }
}
