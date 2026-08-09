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

    /// End timestamp of the newest sample received — when the reading was
    /// taken on the Watch, not when it reached the phone. Without this the UI
    /// has no way to tell a live number from one recorded eight minutes ago,
    /// and presents both as the current heart rate.
    private(set) var lastSampleAt: Date?

    /// How many samples have arrived this session. Alongside the session
    /// clock this is what separates "streaming" from "trickling": a Watch
    /// running a workout delivers every few seconds, one that isn't delivers
    /// every few minutes.
    private(set) var sampleCount: Int = 0

    /// Seconds since the newest sample was recorded, or `nil` before the
    /// first one arrives.
    func sampleAge(at now: Date = Date()) -> TimeInterval? {
        guard let lastSampleAt else { return nil }
        return max(0, now.timeIntervalSince(lastSampleAt))
    }

    /// `true` once the newest sample is old enough that showing it as the
    /// current heart rate would be a lie.
    func isStale(at now: Date = Date()) -> Bool {
        guard let age = sampleAge(at: now) else { return true }
        return age > 90
    }

    private let store = HKHealthStore()
    private var query: HKAnchoredObjectQuery?
    private var anchor: HKQueryAnchor?
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

        reset()
        sessionStart = start
        isStreaming = true

        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: nil,
            options: .strictStartDate
        )

        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: predicate,
            anchor: nil,
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

    private func handle(samples: [HKSample]?, anchor newAnchor: HKQueryAnchor?) {
        self.anchor = newAnchor
        guard let quantitySamples = samples as? [HKQuantitySample], !quantitySamples.isEmpty else {
            return
        }

        // Order matters for the "current" BPM — latest end date wins.
        let sorted = quantitySamples.sorted { $0.endDate < $1.endDate }
        for sample in sorted {
            let bpm = sample.quantity.doubleValue(for: bpmUnit)
            guard bpm > 0 else { continue }
            sampleSum += bpm
            sampleCount += 1
            let rounded = Int(bpm.rounded())
            if let existingMin = minBPM { minBPM = Swift.min(existingMin, rounded) } else { minBPM = rounded }
            if let existingMax = maxBPM { maxBPM = Swift.max(existingMax, rounded) } else { maxBPM = rounded }
            trace.append(rounded)
        }
        if trace.count > traceLimit {
            trace.removeFirst(trace.count - traceLimit)
        }

        if let latest = sorted.last {
            currentBPM = Int(latest.quantity.doubleValue(for: bpmUnit).rounded())
            lastSampleAt = latest.endDate
        }
        if sampleCount > 0 {
            avgBPM = Int((sampleSum / Double(sampleCount)).rounded())
        }
    }

    private func reset() {
        currentBPM = nil
        trace = []
        minBPM = nil
        maxBPM = nil
        avgBPM = nil
        sampleSum = 0
        sampleCount = 0
        lastSampleAt = nil
        anchor = nil
        sessionStart = nil
    }
}
