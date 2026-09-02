// RecoveryInsightsViewModel.swift
// Vaux
//
// Recovery read against a reference. Each metric is judged against the
// athlete's OWN typical range (mean ± 1 SD over the days outside the peak and
// deload weeks of the current block), so a low HRV means "low for you", and
// the block weeks are shaded so the dip lines up with its cause.

import Foundation
import Observation

struct RecoverySeries {
    /// One slot per day (or per week when aggregated), oldest first.
    var values: [Double?]
    var labels: [String]
    var positions: [BlockPosition?]
    var range: ClosedRange<Double>
    var band: ClosedRange<Double>?
    var latest: Double? { values.last ?? nil }
    var avg7: Double? {
        let w = values.suffix(7).compactMap { $0 }
        return w.isEmpty ? nil : ChartMath.mean(w)
    }
    func slots(where test: (BlockPosition) -> Bool) -> Set<Int> {
        Set(positions.enumerated().compactMap { i, p in (p.map(test) ?? false) ? i : nil })
    }
}

@Observable
final class RecoveryInsightsViewModel {
    enum Window: String, CaseIterable {
        case d30 = "30D", d90 = "90D", all = "ALL"
        var days: Int {
            switch self {
            case .d30: return 30
            case .d90: return 90
            case .all: return 365
            }
        }
    }

    private(set) var history: [Recovery] = []
    private(set) var hrv = RecoverySeries(values: [], labels: [], positions: [], range: 20...60, band: nil)
    private(set) var rhr = RecoverySeries(values: [], labels: [], positions: [], range: 50...80, band: nil)
    private(set) var sleep = RecoverySeries(values: [], labels: [], positions: [], range: 4...9.5, band: nil)
    private(set) var weight = RecoverySeries(values: [], labels: [], positions: [], range: 70...80, band: nil)
    private(set) var loadTonnage: [Double?] = []
    private(set) var loadIsLegs: [Bool] = []
    private(set) var weekGroups: [WeekRangeChart.Group] = []
    private(set) var isAggregated = false
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    var range: Window = .d30

    static let sleepNeed = 7.5
    static let shortNight = 7.0

    private let service = RecoveryService()

    func load(sessions: [WorkoutSession], calendar: BlockCalendar) async {
        isLoading = true
        defer { isLoading = false }
        do {
            history = try await service.fetchHistory(days: range.days)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        rebuild(sessions: sessions, calendar: calendar)
    }

    func rebuild(sessions: [WorkoutSession], calendar: BlockCalendar) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = range.days
        let byDate = Dictionary(history.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let tonnageByDate: [String: (Double, Bool)] = sessions.reduce(into: [:]) { acc, s in
            let prev = acc[s.date] ?? (0, false)
            acc[s.date] = (prev.0 + (s.tonnageKg ?? 0), prev.1 || s.type == "Legs")
        }

        // Daily slots, oldest first.
        var dates: [String] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            if let d = cal.date(byAdding: .day, value: -offset, to: today) { dates.append(f.string(from: d)) }
        }
        let positions = dates.map { calendar.position(onDate: $0) }
        let aggregate = days > 45
        isAggregated = aggregate

        func series(_ key: (Recovery) -> Double?, pad: Double, badBelow: Bool, bandable: Bool) -> RecoverySeries {
            var vals: [Double?] = dates.map { byDate[$0].flatMap(key) }
            var labels = dates
            var pos = positions
            if aggregate {
                // Weekly means keep the chart readable past ~45 days.
                var wv: [Double?] = [], wl: [String] = [], wp: [BlockPosition?] = []
                var i = 0
                while i < vals.count {
                    let chunk = vals[i..<min(i + 7, vals.count)].compactMap { $0 }
                    wv.append(chunk.isEmpty ? nil : ChartMath.mean(chunk)); wl.append(dates[i]); wp.append(positions[min(i + 6, positions.count - 1)])
                    i += 7
                }
                vals = wv; labels = wl; pos = wp
            }
            let present = vals.compactMap { $0 }
            // Typical range: the days outside this block's peak & deload.
            let calm: [Double] = zip(vals, pos).compactMap { v, p in
                guard let v else { return nil }
                if let p, p.block == calendar.current.block, (p.isPeak || p.isDeload) { return nil }
                return v
            }
            let basis = calm.count >= 5 ? calm : present
            var band: ClosedRange<Double>? = nil
            if bandable, basis.count >= 5 {
                let m = ChartMath.mean(basis), sd = max(ChartMath.stdDev(basis), 0.5)
                band = (m - sd)...(m + sd)
            }
            let lo = min(present.min() ?? 0, band?.lowerBound ?? .infinity) - pad
            let hi = max(present.max() ?? 1, band?.upperBound ?? -.infinity) + pad
            return RecoverySeries(values: vals, labels: labels, positions: pos, range: lo...(max(hi, lo + 1)), band: band)
        }

        hrv = series({ $0.hrv }, pad: 4, badBelow: true, bandable: true)
        rhr = series({ $0.restingHr }, pad: 3, badBelow: false, bandable: true)
        sleep = series({ $0.sleepHours }, pad: 0, badBelow: true, bandable: false)
        sleep.range = 4...9.5
        weight = series({ $0.weightKg }, pad: 0.4, badBelow: false, bandable: false)

        if aggregate {
            loadTonnage = []; loadIsLegs = []
        } else {
            loadTonnage = dates.map { tonnageByDate[$0].map { $0.0 } }
            loadIsLegs = dates.map { tonnageByDate[$0]?.1 ?? false }
        }

        // HRV by block week (daily data only).
        var groups: [BlockPosition: [Double]] = [:]
        for (d, p) in zip(dates, positions) {
            if let p, let v = byDate[d]?.hrv { groups[p, default: []].append(v) }
        }
        weekGroups = groups.keys.sorted().suffix(5).map { p in
            let isNow = p == calendar.current
            let label = p.block == calendar.current.block ? "W\(p.week)\(p.isPeak ? " PEAK" : "")\(isNow ? " · NOW" : "")" : "\(p.shortBlockLabel) W\(p.week)"
            return WeekRangeChart.Group(label: label, values: groups[p] ?? [], highlight: isNow)
        }
    }

    // MARK: - Derived facts

    var hrvBelowLast10: Int {
        guard let b = hrv.band else { return 0 }
        return hrv.values.suffix(10).compactMap { $0 }.filter { $0 < b.lowerBound }.count
    }
    var hrvBelowLast7: Int {
        guard let b = hrv.band else { return 0 }
        return hrv.values.suffix(7).compactMap { $0 }.filter { $0 < b.lowerBound }.count
    }
    var rhrAboveCount: Int {
        guard let b = rhr.band else { return 0 }
        return rhr.values.compactMap { $0 }.filter { $0 > b.upperBound }.count
    }
    var shortNights: Int { sleep.values.compactMap { $0 }.filter { $0 < Self.shortNight }.count }
    var sleepDebtLast7: Double { sleep.values.suffix(7).compactMap { $0 }.reduce(0) { $0 + max(0, Self.sleepNeed - $1) } }
    var hrv30DayAvg: Double? { let v = hrv.values.compactMap { $0 }; return v.isEmpty ? nil : ChartMath.mean(v) }
    var hrvDeltaVsAvgPct: Double? {
        guard let l = hrv.latest, let a = hrv30DayAvg, a > 0 else { return nil }
        return (l - a) / a * 100
    }
    /// Mean HRV drop in the current block's peak week vs the band centre.
    var peakWeekHRVDrop: Double? {
        guard let band = hrv.band else { return nil }
        let peak = zip(hrv.values, hrv.positions).compactMap { v, p -> Double? in
            guard let v, let p, p.isPeak, p.block == (hrv.positions.compactMap { $0 }.map(\.block).max() ?? 0) else { return nil }
            return v
        }
        guard !peak.isEmpty else { return nil }
        return (band.lowerBound + band.upperBound) / 2 - ChartMath.mean(peak)
    }
    var shortNightsInPeakWeek: Int {
        zip(sleep.values, sleep.positions).filter { v, p in (v ?? 9) < Self.shortNight && (p?.isPeak ?? false) }.count
    }

    static func diagnosis(_ vm: RecoveryInsightsViewModel) -> AttributedString {
        guard vm.hrv.latest != nil else {
            return .editorial([("No recovery readings in this window. Sync Apple Health or log a weight to start the record.", false)])
        }
        var parts: [(String, Bool)] = []
        let below7 = vm.hrvBelowLast7
        if vm.hrv.band == nil {
            parts.append(("Your typical HRV range needs about a week of readings before it can be drawn.", false))
        } else if below7 >= 4 {
            parts.append(("HRV has sat under your range on ", false)); parts.append(("\(below7) of the last 7", true)); parts.append((" days. ", false))
        } else if below7 == 0 {
            parts.append(("HRV has held inside your range all week. ", false))
        } else {
            parts.append(("HRV dipped under your range on ", false)); parts.append(("\(below7)", true)); parts.append((below7 == 1 ? " day this week. " : " days this week. ", false))
        }
        let peakShort = vm.shortNightsInPeakWeek
        if peakShort > 0 {
            parts.append(("Sleep is the lever: ", false)); parts.append(("\(peakShort) short night\(peakShort == 1 ? "" : "s")", true)); parts.append((" fell in peak week. ", false))
        } else if vm.sleepDebtLast7 > 1 {
            parts.append(("Sleep debt this week is ", false)); parts.append((SleepBarsChart.hm(vm.sleepDebtLast7), true)); parts.append((" against a 7:30 need. ", false))
        }
        return .editorial(parts)
    }

    static func coachPrompt(_ vm: RecoveryInsightsViewModel) -> String? {
        guard let latest = vm.hrv.latest else { return nil }
        var lines = ["Looking at my Recovery tab (last \(vm.range.days) days):", "- HRV today \(Int(latest)) ms"]
        if let b = vm.hrv.band { lines.append("- my typical HRV range is \(Int(b.lowerBound))–\(Int(b.upperBound)) ms; \(vm.hrvBelowLast7) of the last 7 days were below it") }
        if let r = vm.rhr.latest { lines.append("- resting HR \(Int(r)) bpm; \(vm.rhrAboveCount) days above my range this window") }
        lines.append("- \(vm.shortNights) nights under 7h; sleep debt this week \(SleepBarsChart.hm(vm.sleepDebtLast7))")
        lines.append("How should this shape the next sessions?")
        return lines.joined(separator: "\n")
    }
}
