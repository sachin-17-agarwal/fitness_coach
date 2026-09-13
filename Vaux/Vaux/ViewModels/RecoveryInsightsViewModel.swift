// RecoveryInsightsViewModel.swift
// Vaux
//
// Recovery read against a reference. Each metric is judged against the
// athlete's OWN typical range — mean ± 1 SD of a six-week baseline that ends
// a week ago, HRV on the natural log — so a low HRV means "low for you", and
// the block weeks are shaded so the dip lines up with its cause.
//
// Two layers, deliberately. The CHART follows the window the athlete picks
// and past 45 days aggregates to weekly means so it stays readable. The FACTS
// — the range, the 7-day average, days below, short nights, the diagnosis —
// come from daily readings over a fixed 56-day window whatever is drawn.
// They used to be computed from the chart's own values, so switching 30D to
// 90D changed "your range" from 34–43 to 37–41 and the 7-day average from 42
// to 39 for the same morning: the same numbers, aggregated, judged again. A
// fact about today cannot depend on how much history sits under it.

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
    /// Daily series over the last `factsDays`, window-independent. Every
    /// headline fact reads from these, never from the chart series.
    private(set) var dailyHRV = RecoverySeries(values: [], labels: [], positions: [], range: 20...60, band: nil)
    private(set) var dailyRHR = RecoverySeries(values: [], labels: [], positions: [], range: 50...80, band: nil)
    private(set) var dailySleep = RecoverySeries(values: [], labels: [], positions: [], range: 4...9.5, band: nil)
    private(set) var dailyWeight = RecoverySeries(values: [], labels: [], positions: [], range: 70...80, band: nil)
    /// Days of daily history the facts are computed over: a 7-day window
    /// plus the 42-day baseline behind it, plus a week of slack.
    static let factsDays = 56
    static let baselineDays = 42
    static let minBaseline = 10
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    var range: Window = .d30

    static let sleepNeed = 7.5
    static let shortNight = 7.0
    /// A recorded night under this is missing data, not sleep.
    static let missingSleepBelow = 2.0

    private let service = RecoveryService()

    func load(sessions: [WorkoutSession], calendar: BlockCalendar) async {
        isLoading = true
        defer { isLoading = false }
        do {
            // At least the facts window, whatever the chart shows.
            history = try await service.fetchHistory(days: max(range.days, Self.factsDays))
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

        // ── Facts: daily, fixed window, baseline band ─────────────────────
        var factDates: [String] = []
        for offset in stride(from: Self.factsDays - 1, through: 0, by: -1) {
            if let d = cal.date(byAdding: .day, value: -offset, to: today) { factDates.append(f.string(from: d)) }
        }
        let factPositions = factDates.map { calendar.position(onDate: $0) }

        /// Mean ± 1 SD of the 42 days ending a week ago (HRV in log space,
        /// converted back), the same construction the coach's recovery read
        /// uses. Under `minBaseline` readings there, everything before the
        /// last week stands in; under five readings, no band.
        func baselineBand(_ vals: [Double?], log: Bool) -> ClosedRange<Double>? {
            let n = vals.count
            let rollingStart = max(0, n - 7)
            let baseStart = max(0, rollingStart - Self.baselineDays)
            var basis = vals[baseStart..<rollingStart].compactMap { $0 }.filter { $0 > 0 }
            if basis.count < Self.minBaseline { basis = vals[0..<rollingStart].compactMap { $0 }.filter { $0 > 0 } }
            guard basis.count >= 5 else { return nil }
            let xs = log ? basis.map { Foundation.log($0) } : basis
            let m = ChartMath.mean(xs), sd = max(ChartMath.stdDev(xs), log ? 0.02 : 0.5)
            return log ? exp(m - sd)...exp(m + sd) : (m - sd)...(m + sd)
        }

        func daily(_ key: (Recovery) -> Double?, pad: Double, band: ClosedRange<Double>?) -> RecoverySeries {
            let vals: [Double?] = factDates.map { byDate[$0].flatMap(key) }
            let present = vals.compactMap { $0 }
            let lo = min(present.min() ?? 0, band?.lowerBound ?? .infinity) - pad
            let hi = max(present.max() ?? 1, band?.upperBound ?? -.infinity) + pad
            return RecoverySeries(values: vals, labels: factDates, positions: factPositions, range: lo...(max(hi, lo + 1)), band: band)
        }

        let hrvDailyVals: [Double?] = factDates.map { byDate[$0]?.hrv }
        let rhrDailyVals: [Double?] = factDates.map { byDate[$0]?.restingHr }
        let hrvBand = baselineBand(hrvDailyVals, log: true)
        let rhrBand = baselineBand(rhrDailyVals, log: false)
        dailyHRV = daily({ $0.hrv }, pad: 4, band: hrvBand)
        dailyRHR = daily({ $0.restingHr }, pad: 3, band: rhrBand)
        dailySleep = daily({ $0.sleepHours.flatMap { $0 < Self.missingSleepBelow ? nil : $0 } }, pad: 0, band: nil)
        dailySleep.range = 4...9.5
        dailyWeight = daily({ $0.weightKg }, pad: 0.4, band: nil)

        // ── Chart: the window, aggregated past 45 days, band from the facts ─
        func series(_ key: (Recovery) -> Double?, pad: Double, badBelow: Bool, bandable: Bool,
                    fixedBand: ClosedRange<Double>? = nil) -> RecoverySeries {
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
            // The shaded range is the FACTS' band, the same in every window.
            let band: ClosedRange<Double>? = bandable ? fixedBand : nil
            let lo = min(present.min() ?? 0, band?.lowerBound ?? .infinity) - pad
            let hi = max(present.max() ?? 1, band?.upperBound ?? -.infinity) + pad
            return RecoverySeries(values: vals, labels: labels, positions: pos, range: lo...(max(hi, lo + 1)), band: band)
        }

        hrv = series({ $0.hrv }, pad: 4, badBelow: true, bandable: true, fixedBand: hrvBand)
        rhr = series({ $0.restingHr }, pad: 3, badBelow: false, bandable: true, fixedBand: rhrBand)
        // Under two hours is the watch not being worn, or flat, not a night's
        // sleep. Kept as a value it drew a sliver of a bar, counted as a night
        // under 7h and put a full 7:30 on the debt — two such nights were
        // most of a "−13:52" week.
        sleep = series({ $0.sleepHours.flatMap { $0 < Self.missingSleepBelow ? nil : $0 } }, pad: 0, badBelow: true, bandable: false)
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

    // Every fact below reads the DAILY series, so it is the same on 30D, 90D
    // and ALL. The chart may be weekly means; the facts never are.
    var hrvBand: ClosedRange<Double>? { dailyHRV.band }
    var rhrBand: ClosedRange<Double>? { dailyRHR.band }
    var hrvAvg7: Double? { dailyHRV.avg7 }
    var hrvLatest: Double? { dailyHRV.values.last { $0 != nil } ?? nil }
    var rhrLatest: Double? { dailyRHR.values.last { $0 != nil } ?? nil }
    var sleepLatest: Double? { dailySleep.values.last { $0 != nil } ?? nil }
    /// The most recent weigh-in on record, not today's slot — a day without
    /// a weigh-in showed a dash beside a chart full of dots.
    var weightLatest: Double? { dailyWeight.values.last { $0 != nil } ?? nil }

    var hrvBelowLast10: Int {
        guard let b = hrvBand else { return 0 }
        return dailyHRV.values.suffix(10).compactMap { $0 }.filter { $0 < b.lowerBound }.count
    }
    var hrvBelowLast7: Int {
        guard let b = hrvBand else { return 0 }
        return dailyHRV.values.suffix(7).compactMap { $0 }.filter { $0 < b.lowerBound }.count
    }
    /// Days above the resting-HR range in the last ten, like the HRV read.
    var rhrAboveCount: Int {
        guard let b = rhrBand else { return 0 }
        return dailyRHR.values.suffix(10).compactMap { $0 }.filter { $0 > b.upperBound }.count
    }
    var shortNights: Int { dailySleep.values.compactMap { $0 }.filter { $0 < Self.shortNight }.count }
    /// Short nights in the same seven nights the debt is summed over, so the
    /// eyebrow's two numbers describe one week rather than a month and a week.
    var shortNightsLast7: Int { dailySleep.values.suffix(7).compactMap { $0 }.filter { $0 < Self.shortNight }.count }
    var sleepDebtLast7: Double { dailySleep.values.suffix(7).compactMap { $0 }.reduce(0) { $0 + max(0, Self.sleepNeed - $1) } }
    var hrv30DayAvg: Double? { let v = dailyHRV.values.suffix(30).compactMap { $0 }; return v.isEmpty ? nil : ChartMath.mean(v) }
    var hrvDeltaVsAvgPct: Double? {
        guard let l = hrvLatest, let a = hrv30DayAvg, a > 0 else { return nil }
        return (l - a) / a * 100
    }
    /// Mean HRV drop in the current block's peak week vs the band centre.
    var peakWeekHRVDrop: Double? {
        guard let band = hrvBand else { return nil }
        let peak = zip(dailyHRV.values, dailyHRV.positions).compactMap { v, p -> Double? in
            guard let v, let p, p.isPeak, p.block == (dailyHRV.positions.compactMap { $0 }.map(\.block).max() ?? 0) else { return nil }
            return v
        }
        guard !peak.isEmpty else { return nil }
        return (band.lowerBound + band.upperBound) / 2 - ChartMath.mean(peak)
    }
    var shortNightsInPeakWeek: Int {
        zip(dailySleep.values, dailySleep.positions).filter { v, p in (v ?? 9) < Self.shortNight && (p?.isPeak ?? false) }.count
    }

    static func diagnosis(_ vm: RecoveryInsightsViewModel) -> AttributedString {
        guard vm.hrvLatest != nil else {
            return .editorial([("No recovery readings in this window. Sync Apple Health or log a weight to start the record.", false)])
        }
        var parts: [(String, Bool)] = []
        let below7 = vm.hrvBelowLast7
        if vm.hrvBand == nil {
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
        guard let latest = vm.hrvLatest else { return nil }
        var lines = ["Looking at my Recovery tab (last \(vm.range.days) days):", "- HRV today \(Int(latest)) ms"]
        if let b = vm.hrvBand { lines.append("- my typical HRV range is \(Int(b.lowerBound))–\(Int(b.upperBound)) ms; \(vm.hrvBelowLast7) of the last 7 days were below it") }
        if let r = vm.rhrLatest { lines.append("- resting HR \(Int(r)) bpm; \(vm.rhrAboveCount) of the last 10 days above my range") }
        lines.append("- \(vm.shortNightsLast7) nights under 7h this week; sleep debt this week \(SleepBarsChart.hm(vm.sleepDebtLast7))")
        lines.append("How should this shape the next sessions?")
        return lines.joined(separator: "\n")
    }
}
