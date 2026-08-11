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

    /// Observed delivery rate in seconds per sample, once there is enough to
    /// mean anything. About 5s is a Watch running a workout.
    func secondsPerSample(at now: Date = Date()) -> Double? {
        guard let sessionStart, sampleCount >= 5 else { return nil }
        let elapsed = now.timeIntervalSince(sessionStart)
        guard elapsed > 0 else { return nil }
        return elapsed / Double(sampleCount)
    }

    private let store = HKHealthStore()
    private var query: HKAnchoredObjectQuery?
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
        ) { [weak self] _, samples, _, _, _ in
            self?.handle(samples: samples)
        }
        query.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.handle(samples: samples)
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
    private func handle(samples: [HKSample]?) {
        guard let quantitySamples = samples as? [HKQuantitySample], !quantitySamples.isEmpty else {
            return
        }

        // Order matters for the "current" BPM — latest end date wins.
        let readings = quantitySamples
            .sorted { $0.endDate < $1.endDate }
            .compactMap { sample -> Reading? in
                let bpm = sample.quantity.doubleValue(for: bpmUnit)
                guard bpm > 0 else { return nil }
                return Reading(bpm: Int(bpm.rounded()), at: sample.endDate)
            }
        guard !readings.isEmpty else { return }

        // Every property `apply` touches is read by SwiftUI through
        // @Observable. Mutating observable state off the main thread does not
        // reliably invalidate the views observing it, so the card stayed
        // pinned to whatever value happened to be there when it was first
        // built while the model moved on underneath — a heart rate frozen at
        // one number for a whole session. This hop is what makes it move.
        DispatchQueue.main.async { [weak self] in
            self?.apply(readings)
        }
    }

    private func apply(_ readings: [Reading]) {
        for reading in readings {
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
        }
        if trace.count > traceLimit {
            trace.removeFirst(trace.count - traceLimit)
        }

        if let latest = readings.last {
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
        minBPM = nil
        maxBPM = nil
        avgBPM = nil
        sampleSum = 0
        sampleCount = 0
        lastSampleAt = nil
        lastDeliveryAt = nil
        sessionStart = nil
    }
}
