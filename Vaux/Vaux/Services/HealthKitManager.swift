import Foundation
import HealthKit

final class HealthKitManager {
    static let shared = HealthKitManager()
    private let store = HKHealthStore()
    private let recoveryService = RecoveryService()
    private var backgroundObserversActive = false
    private let lastSyncKey = "vaux.healthkit.lastSyncAt"

    private let readTypes: Set<HKObjectType> = {
        var types = Set<HKObjectType>()
        let quantityTypes: [HKQuantityTypeIdentifier] = [
            .heartRateVariabilitySDNN, .restingHeartRate, .heartRate,
            .stepCount, .activeEnergyBurned, .appleExerciseTime,
            .bodyMass, .bodyFatPercentage, .respiratoryRate, .vo2Max
        ]
        for id in quantityTypes {
            if let t = HKQuantityType.quantityType(forIdentifier: id) {
                types.insert(t)
            }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        types.insert(HKObjectType.workoutType())
        return types
    }()

    /// Metrics that warrant a background refresh when Apple Health ingests new data.
    private let observedIdentifiers: [HKQuantityTypeIdentifier] = [
        .heartRateVariabilitySDNN,
        .restingHeartRate,
        .bodyMass,
        .stepCount,
        .activeEnergyBurned
    ]

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    var lastSyncDate: Date? {
        UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    // MARK: - Public sync API

    /// Syncs today's metrics into Supabase. Tolerates per-metric failures so a
    /// single missing permission doesn't abort the whole sync.
    func syncToSupabase() async throws {
        try await syncDay(Date())
    }

    /// Back-fills the most recent `days` calendar days. Useful on first launch
    /// so the dashboard sparkline and history view populate immediately.
    func syncRecent(days: Int) async throws {
        let calendar = Calendar.current
        for offset in 0..<max(1, days) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            do {
                try await syncDay(day)
            } catch {
                print("[HealthKit] Day sync failed for offset \(offset): \(error.localizedDescription)")
            }
        }
    }

    /// Syncs a specific calendar day (local timezone).
    func syncDay(_ day: Date) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start

        let hrv = await safe { try await queryAverage(.heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli), start: start, end: end) }
        let rhr = await safe { try await queryAverage(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end) }
        let hr = await safe { try await queryAverage(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end) }
        let steps = await safe { try await querySum(.stepCount, unit: .count(), start: start, end: end) }
        let energy = await safe { try await querySum(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: end) }
        let exercise = await safe { try await querySum(.appleExerciseTime, unit: .minute(), start: start, end: end) }
        let weight = await safe { try await queryLatest(.bodyMass, unit: .gramUnit(with: .kilo), endingBefore: end) }
        let bodyFat = await safe { try await queryLatest(.bodyFatPercentage, unit: .percent(), endingBefore: end) }
        let resp = await safe { try await queryAverage(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end) }
        let vo2 = await safe { try await queryLatest(.vo2Max, unit: HKUnit(from: "ml/kg*min"), endingBefore: end) }
        let sleep = await safe { try await querySleepHours(for: start) }

        // HRV status compares today's value against the 7-day average.
        let hrvStatus: String?
        if let hrv {
            hrvStatus = await resolveHRVStatus(current: hrv)
        } else {
            hrvStatus = nil
        }

        let formatter = Self.dateFormatter
        let recovery = Recovery(
            id: nil,
            date: formatter.string(from: start),
            sleepHours: sleep,
            hrv: hrv,
            hrvStatus: hrvStatus,
            restingHr: rhr,
            heartRate: hr,
            steps: steps.map { Int($0) },
            activeEnergyKcal: energy,
            weightKg: weight,
            bodyFatPct: bodyFat.map { $0 * 100 },
            exerciseMinutes: exercise.map { Int($0) },
            respiratoryRate: resp,
            vo2Max: vo2
        )

        try await recoveryService.saveRecovery(recovery)
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
    }

    // MARK: - Workouts (Apple Watch import)

    /// Returns today's `HKWorkout` samples (local timezone). Used by the
    /// Cardio+Abs / Yoga log view to import Apple Watch sessions instead of
    /// asking the user to type them in.
    func fetchTodaysWorkouts() async throws -> [HKWorkout] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }

    // MARK: - Background delivery

    /// Registers observer queries so iOS wakes the app and refreshes Supabase
    /// whenever Apple Health ingests new data for the key metrics.
    func enableBackgroundSync() {
        guard HKHealthStore.isHealthDataAvailable(), !backgroundObserversActive else { return }
        backgroundObserversActive = true

        for identifier in observedIdentifiers {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }

            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                if let error {
                    print("[HealthKit] Observer error (\(identifier.rawValue)): \(error.localizedDescription)")
                    completion()
                    return
                }
                Task {
                    do { try await self?.syncToSupabase() }
                    catch { print("[HealthKit] Background sync failed: \(error.localizedDescription)") }
                    completion()
                }
            }
            store.execute(query)

            store.enableBackgroundDelivery(for: type, frequency: .hourly) { success, error in
                if let error {
                    print("[HealthKit] enableBackgroundDelivery(\(identifier.rawValue)) failed: \(error.localizedDescription)")
                } else if !success {
                    print("[HealthKit] enableBackgroundDelivery(\(identifier.rawValue)) returned false")
                }
            }
        }
    }

    // MARK: - HRV status

    /// Mirrors the backend logic in `webhook.py::_get_hrv_status` so the two
    /// code paths produce the same classification strings.
    private func resolveHRVStatus(current: Double) async -> String {
        guard let history = try? await recoveryService.fetchHistory(days: 7) else {
            return "Unknown"
        }
        let values = history.compactMap(\.hrv).filter { $0 > 0 }
        guard !values.isEmpty else { return "Baseline building" }
        let avg = values.reduce(0, +) / Double(values.count)
        guard avg > 0 else { return "Baseline building" }
        let diff = ((current - avg) / avg) * 100
        if diff >= 10 { return "Elevated" }
        if diff >= -10 { return "Normal" }
        if diff >= -20 { return "Suppressed" }
        return "Very low"
    }

    // MARK: - HealthKit helpers

    private func queryAverage(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .discreteAverage) { _, stats, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func querySum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// Returns the most recent sample at or before `endingBefore`.
    private func queryLatest(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, endingBefore: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: nil, end: endingBefore, options: .strictEndDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// Sleep samples that END on the target day. This correctly captures
    /// sleep sessions that started the previous evening — the common case.
    private func querySleepHours(for day: Date) async throws -> Double? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                guard let categorySamples = samples as? [HKCategorySample] else {
                    continuation.resume(returning: nil); return
                }
                let asleep = categorySamples.filter { sample in
                    sample.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue ||
                    sample.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue ||
                    sample.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue ||
                    sample.value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                }
                guard !asleep.isEmpty else {
                    continuation.resume(returning: nil); return
                }
                // Collapse overlapping ranges so double-counting across devices
                // (Watch + iPhone) doesn't inflate the total.
                let merged = Self.mergeIntervals(asleep.map { ($0.startDate, $0.endDate) })
                let total = merged.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) }
                continuation.resume(returning: total / 3600.0)
            }
            store.execute(query)
        }
    }

    // MARK: - Utilities

    private func safe<T>(_ op: () async throws -> T?) async -> T? {
        do { return try await op() }
        catch {
            print("[HealthKit] Metric query failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static func mergeIntervals(_ ranges: [(Date, Date)]) -> [(Date, Date)] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.0 < $1.0 }
        var merged: [(Date, Date)] = [sorted[0]]
        for current in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if current.0 <= last.1 {
                merged[merged.count - 1] = (last.0, max(last.1, current.1))
            } else {
                merged.append(current)
            }
        }
        return merged
    }
}

