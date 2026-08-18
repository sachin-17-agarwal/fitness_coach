// HeartRateMonitor.swift
// Vaux
//
// Streams live heart-rate samples from HealthKit during an active workout.
// Relies on the Watch → iPhone HealthKit bridge, so BPM updates arrive with
// a short lag (typically 5–10s) rather than true real-time. A companion
// watchOS app using HKWorkoutSession would be required for sub-second
// streaming.

import Foundation
import HealthKit
import Observation

@Observable
final class HeartRateMonitor {
    /// Most recent BPM sample seen during this session, or `nil` before the
    /// first sample arrives.
    private(set) var currentBPM: Int?
    /// Running aggregates over the session window.
    private(set) var minBPM: Int?
    private(set) var maxBPM: Int?
    private(set) var avgBPM: Int?
    /// `true` while an anchored query is active.
    private(set) var isStreaming = false

    /// Every heart-rate sample this session, in arrival order.
    ///
    /// Built from real HealthKit deliveries rather than a timer, and kept for
    /// the whole session rather than one rest. Both of those matter: the
    /// Watch → iPhone bridge batches samples, so over a single 90-second rest
    /// there is frequently no second distinct reading at all — polling
    /// `currentBPM` once a second just re-recorded the same stale value and
    /// drew a dead-flat line that looked like a broken chart. Across a
    /// 30-60 minute session the same sparse feed has plenty of shape: it
    /// climbs through working sets and falls back during rests.
    private(set) var trace: [Int] = []

    /// Caps the trace so a long session can't grow it without bound. A couple
    /// of hundred points is far more than a sparkline can resolve anyway.
    private let traceLimit = 240

    /// One reading with the time it was taken, exposed so a view can ask about
    /// a window rather than the whole session.
    ///
    /// `trace` alone cannot answer the question the athlete is actually asking
    /// during a rest — "is it coming down?" — because a bare [Int] has no way
    /// to say which points belong to the last two minutes. Plotting all of it
    /// drew thirty minutes of climbs and falls squeezed into 250 points of
    /// noise, which is why the card showed a busy line that meant nothing.
    struct Sample: Identifiable, Equatable {
        let bpm: Int
        let at: Date
        var id: Date { at }
    }

    private(set) var samples: [Sample] = []

    /// Readings from the last `seconds`, oldest first.
    ///
    /// Three minutes is the useful default: long enough to contain the working
    /// set's peak and the descent after it, so the shape reads as a recovery
    /// curve rather than a squiggle.
    func samples(inLast seconds: TimeInterval, at now: Date = Date()) -> [Sample] {
        let cutoff = now.addingTimeInterval(-seconds)
        return samples.filter { $0.at >= cutoff }
    }

    /// Highest reading in the window — the peak being recovered FROM.
    func peak(inLast seconds: TimeInterval, at now: Date = Date()) -> Int? {
        samples(inLast: seconds, at: now).map(\.bpm).max()
    }

    /// Time since that peak, which stands in for "how long since the set
    /// ended". Without it a drop is not comparable to anything: 35 bpm over 45
    /// seconds and 35 over three minutes are different events.
    func secondsSincePeak(inLast seconds: TimeInterval, at now: Date = Date()) -> TimeInterval? {
        let window = samples(inLast: seconds, at: now)
        guard let peak = window.map(\.bpm).max(),
              let peakAt = window.last(where: { $0.bpm == peak })?.at else { return nil }
        let elapsed = now.timeIntervalSince(peakAt)
        return elapsed > 0 ? elapsed : nil
    }

    /// The window every recovery figure is measured over.
    ///
    /// Sixty seconds, fixed, because heart-rate recovery is biexponential — a
    /// fast parasympathetic phase over roughly the first minute, then a much
    /// flatter tail. Dividing a drop by however long the rest happened to last
    /// therefore does NOT normalise it: a 60s rest samples only the steep part
    /// and reads fast, a 150s rest averages in the tail and reads slow. Rests
    /// here run 60s between ramps and 120-180s after working sets, so a rate
    /// computed that way tracks the rest length and nothing else — it would
    /// have reported fatigue after every top set and recovery after every
    /// warm-up, in every session, forever.
    ///
    /// HRR60 is the standard clinical measure for exactly this reason, and
    /// being a fixed window it is comparable between rests.
    static let recoveryWindow: TimeInterval = 60

    /// Heart-rate recovery across one completed rest: bpm fallen in the first
    /// minute after the peak.
    struct RestRecovery: Equatable {
        /// Drop from the peak over `recoveryWindow`.
        let drop: Int
    }

    private(set) var restRecoveries: [RestRecovery] = []

    /// Fold a finished rest into the session's record.
    ///
    /// Rests shorter than the window are skipped rather than extrapolated — a
    /// rest cut short at 25 seconds has no HRR60, and inventing one from a
    /// partial curve is how the previous version got its bias.
    func recordRestRecovery(from start: Date, to end: Date) {
        guard end.timeIntervalSince(start) >= Self.recoveryWindow else { return }
        let window = samples.filter { $0.at >= start && $0.at <= end }
        guard let peak = window.map(\.bpm).max(),
              let peakAt = window.last(where: { $0.bpm == peak })?.at else { return }
        // Measured from the peak, not from the start of the rest: the peak is
        // when the effort actually stopped.
        let cutoff = peakAt.addingTimeInterval(Self.recoveryWindow)
        guard end >= cutoff else { return }
        let atCutoff = window.last { $0.at <= cutoff }
        guard let after = atCutoff?.bpm, peak > after else { return }
        restRecoveries.append(RestRecovery(drop: peak - after))
    }

    /// The session's typical HRR60, as a median.
    ///
    /// Median rather than mean: one rest spent talking to the coach with the
    /// phone down would drag an average far enough to make the comparison
    /// meaningless.
    var typicalRecoveryDrop: Double? {
        guard restRecoveries.count >= 2 else { return nil }
        let drops = restRecoveries.map { Double($0.drop) }.sorted()
        let mid = drops.count / 2
        return drops.count.isMultiple(of: 2)
            ? (drops[mid - 1] + drops[mid]) / 2
            : drops[mid]
    }

    /// HRR60 for the rest currently under way, once a minute has passed since
    /// the peak. Nil before that — there is no partial answer worth showing.
    func liveRecoveryDrop(at now: Date = Date()) -> Int? {
        guard let peak = peak(inLast: 300, at: now),
              let elapsed = secondsSincePeak(inLast: 300, at: now),
              elapsed >= Self.recoveryWindow,
              let current = currentBPM,
              peak > current else { return nil }
        return peak - current
    }

    /// How far the heart rate has fallen from that peak.
    ///
    /// Never negative: the peak is taken from the same window the current
    /// reading sits in, so at worst the current reading IS the peak and this
    /// returns 0. A caller wanting "is it still rising" should read 0 as that
    /// rather than expecting a negative number.
    func dropFromPeak(inLast seconds: TimeInterval, at now: Date = Date()) -> Int? {
        guard let peak = peak(inLast: seconds, at: now), let current = currentBPM else { return nil }
        return peak - current
    }

    /// End timestamp of the newest sample received — when the reading was
    /// taken on the Watch, not when it reached the phone. Without this the UI
    /// has no way to tell a live number from one recorded eight minutes ago,
    /// and presents both as the current heart rate.
    private(set) var lastSampleAt: Date?

    /// Wall-clock time the last BATCH arrived on the phone — a different clock
    /// from `lastSampleAt`, and the distinction matters.
    ///
    /// The Watch→iPhone bridge delivers in batches, not sample by sample. A
    /// batch carries several minutes of readings at once, so the newest sample
    /// inside it is ALREADY minutes old at the moment it lands. Judging health
    /// by sample age therefore condemns a perfectly working feed: a session
    /// delivering 112 samples in nine minutes — dead-on the 5-second Watch
    /// workout cadence — still showed a newest sample three minutes behind,
    /// and got called stalled for it.
    ///
    /// Whether data is still FLOWING is this clock. How far behind real time
    /// the reading is, is the other one. Both are worth showing; only this one
    /// means something has gone wrong.
    private(set) var lastDeliveryAt: Date?

    /// How many samples have arrived this session. Against the session clock
    /// this gives the true delivery rate: roughly one per 5s means the Watch
    /// is running a workout, one per few minutes means it is not.
    private(set) var sampleCount: Int = 0

    /// Seconds since the newest sample was RECORDED, or `nil` before the first
    /// one arrives. Expect this to sit in the minutes even on a healthy feed —
    /// it is the bridge's lag, not a fault.
    func sampleAge(at now: Date = Date()) -> TimeInterval? {
        guard let lastSampleAt else { return nil }
        return max(0, now.timeIntervalSince(lastSampleAt))
    }

    /// Seconds since the last batch landed, or `nil` before the first one.
    func deliveryAge(at now: Date = Date()) -> TimeInterval? {
        guard let lastDeliveryAt else { return nil }
        return max(0, now.timeIntervalSince(lastDeliveryAt))
    }

    /// `true` when the reading on screen is far enough behind real time that
    /// presenting it as the current heart rate would overstate it. Says
    /// nothing about whether the feed is broken — see `hasStalled`.
    func isLagging(at now: Date = Date()) -> Bool {
        guard let age = sampleAge(at: now) else { return true }
        return age > 60
    }

    /// `true` when no batch has arrived for long enough that the feed itself
    /// has stopped, rather than merely running behind. Three minutes is past
    /// the batching interval seen in normal operation.
    func hasStalled(at now: Date = Date()) -> Bool {
        guard let age = deliveryAge(at: now) else { return true }
        return age > 180
    }

    private let store = HKHealthStore()
    private var query: HKAnchoredObjectQuery?
    /// Where the last delivery left off. Removed once as "unused" — it is
    /// precisely what makes `resume()` safe, because a query rebuilt with it
    /// picks up from that point instead of replaying the session.
    private var anchor: HKQueryAnchor?
    /// Newest sample end date already folded into the aggregates. A resumed
    /// query can hand back rows it has given us before; without this the trace
    /// would double-count them and the session range would widen for nothing.
    private var lastIngestedEnd: Date?
    private var sessionStart: Date?
    private var sampleSum: Double = 0

    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    /// Starts streaming heart-rate samples with `start` as the session epoch.
    /// Only samples ending at or after `start` count toward the aggregates, so
    /// a reading that arrived moments before the user hit "Begin" doesn't skew
    /// the session average.
    func start(from start: Date = Date()) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        guard !isStreaming else { return }

        _ = type
        reset()
        sessionStart = start
        isStreaming = true
        executeQuery(from: start, anchor: nil)
    }

    /// Rebuilds the query without disturbing anything already collected.
    ///
    /// An anchored query stops delivering when iOS suspends the app, and
    /// nothing brought it back: the query object was still held, `isStreaming`
    /// was still true, and not one further sample ever arrived. From the
    /// outside that looks like a session streaming healthily for six minutes
    /// and then sitting frozen on the same reading for the next eleven, which
    /// is exactly what it did.
    ///
    /// Safe to call at any time. The stored anchor means the rebuilt query
    /// delivers only what has accumulated since the last one stopped, and the
    /// high-water mark catches anything it repeats anyway.
    func resume() {
        guard isStreaming, let sessionStart else { return }
        if let query { store.stop(query) }
        query = nil
        executeQuery(from: sessionStart, anchor: anchor)
    }

    private func executeQuery(from start: Date, anchor startAnchor: HKQueryAnchor?) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }

        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: nil,
            options: .strictStartDate
        )

        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: predicate,
            anchor: startAnchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, _ in
            self?.handle(samples: samples, anchor: newAnchor)
        }
        query.updateHandler = { [weak self] _, samples, _, newAnchor, _ in
            self?.handle(samples: samples, anchor: newAnchor)
        }
        self.query = query
        store.execute(query)
    }

    /// Stops the stream and freezes the aggregates. Safe to call multiple
    /// times; subsequent `start` calls will reset state.
    func stop() {
        if let query { store.stop(query) }
        query = nil
        isStreaming = false
    }

    /// Human zone label for a given BPM, using a conservative % of a
    /// 220-age estimate. Falls back to a generic split when age is unknown.
    func zoneLabel(for bpm: Int, age: Int? = nil) -> String {
        let max = Double(220 - (age ?? 30))
        let pct = Double(bpm) / max
        switch pct {
        case ..<0.5: return "Rest"
        case ..<0.6: return "Warm-up"
        case ..<0.7: return "Zone 2"
        case ..<0.8: return "Zone 3"
        case ..<0.9: return "Zone 4"
        default:     return "Zone 5"
        }
    }

    // MARK: - Private

    /// One sample reduced to plain values. `HKQuantitySample` is a reference
    /// type; converting on the delivery queue means the hop to main carries
    /// nothing but numbers.
    private struct Reading {
        let bpm: Int
        let at: Date
    }

    /// Runs on HealthKit's private background queue — every anchored-query
    /// handler does.
    private func handle(samples: [HKSample]?, anchor newAnchor: HKQueryAnchor?) {
        let quantitySamples = (samples as? [HKQuantitySample]) ?? []

        // Order matters for the "current" BPM — latest end date wins.
        let readings = quantitySamples
            .sorted { $0.endDate < $1.endDate }
            .compactMap { sample -> Reading? in
                let bpm = sample.quantity.doubleValue(for: bpmUnit)
                guard bpm > 0 else { return nil }
                return Reading(bpm: Int(bpm.rounded()), at: sample.endDate)
            }
        // Hops even with nothing in it, so the anchor still advances.
        // Every property `apply` touches is read by SwiftUI through
        // @Observable. Mutating observable state off the main thread does not
        // reliably invalidate the views observing it, so the card stayed
        // pinned to whatever value happened to be there when it was first
        // built while the model moved on underneath — a heart rate frozen at
        // one number for a whole session. This hop is what makes it move.
        DispatchQueue.main.async { [weak self] in
            self?.apply(readings, anchor: newAnchor)
        }
    }

    private func apply(_ readings: [Reading], anchor newAnchor: HKQueryAnchor?) {
        if let newAnchor { anchor = newAnchor }

        // Only genuinely new readings count. A resumed query may repeat rows
        // it already delivered, and re-folding those would inflate the sample
        // count and widen the session range without any new data existing.
        let fresh = readings.filter { reading in
            guard let mark = lastIngestedEnd else { return true }
            return reading.at > mark
        }
        guard !fresh.isEmpty else { return }
        lastIngestedEnd = fresh.last?.at

        for reading in fresh {
            sampleSum += Double(reading.bpm)
            sampleCount += 1
            if let existingMin = minBPM {
                minBPM = Swift.min(existingMin, reading.bpm)
            } else {
                minBPM = reading.bpm
            }
            if let existingMax = maxBPM {
                maxBPM = Swift.max(existingMax, reading.bpm)
            } else {
                maxBPM = reading.bpm
            }
            trace.append(reading.bpm)
            samples.append(Sample(bpm: reading.bpm, at: reading.at))
        }
        if trace.count > traceLimit {
            trace.removeFirst(trace.count - traceLimit)
        }
        if samples.count > traceLimit {
            samples.removeFirst(samples.count - traceLimit)
        }

        if let latest = fresh.last {
            currentBPM = latest.bpm
            lastSampleAt = latest.at
        }
        // Stamped on arrival, not from the sample — this is the clock that
        // says data is still flowing.
        lastDeliveryAt = Date()
        if sampleCount > 0 {
            avgBPM = Int((sampleSum / Double(sampleCount)).rounded())
        }
    }

    private func reset() {
        currentBPM = nil
        trace = []
        samples = []
        restRecoveries = []
        minBPM = nil
        maxBPM = nil
        avgBPM = nil
        sampleSum = 0
        sampleCount = 0
        lastSampleAt = nil
        lastDeliveryAt = nil
        anchor = nil
        lastIngestedEnd = nil
        sessionStart = nil
    }
}
