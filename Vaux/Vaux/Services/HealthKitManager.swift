import Foundation
import HealthKit

class HealthKitManager {
    static let shared = HealthKitManager()
    private let store = HKHealthStore()
    private let recoveryService = RecoveryService()

    private let readTypes: Set<HKObjectType> = {
        var types = Set<HKObjectType>()
        let quantityTypes: [HKQuantityTypeIdentifier] = [
            .heartRateVariabilitySDNN, .restingHeartRate, .heartRate,
            .stepCount, .activeEnergyBurned, .bodyMass,
            .bodyFatPercentage, .respiratoryRate, .vo2Max
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

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    func syncToSupabase() async throws {
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!

        let hrv = try await queryAverage(.heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli), start: today, end: tomorrow)
        let rhr = try await queryAverage(.restingHeartRate, unit: .count().unitDivided(by: .minute()), start: today, end: tomorrow)
        let hr = try await queryAverage(.heartRate, unit: .count().unitDivided(by: .minute()), start: today, end: tomorrow)
        let steps = try await querySum(.stepCount, unit: .count(), start: today, end: tomorrow)
        let energy = try await querySum(.activeEnergyBurned, unit: .kilocalorie(), start: today, end: tomorrow)
        let weight = try await queryLatest(.bodyMass, unit: .gramUnit(with: .kilo))
        let bodyFat = try await queryLatest(.bodyFatPercentage, unit: .percent())
        let resp = try await queryAverage(.respiratoryRate, unit: .count().unitDivided(by: .minute()), start: today, end: tomorrow)
        let vo2 = try await queryLatest(.vo2Max, unit: HKUnit(from: "ml/kg*min"))
        let sleep = try await querySleepHours(start: today, end: tomorrow)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Australia/Sydney")

        let recovery = Recovery(
            id: nil,
            date: formatter.string(from: today),
            sleepHours: sleep,
            hrv: hrv,
            hrvStatus: nil,
            restingHr: rhr,
            heartRate: hr,
            steps: steps != nil ? Int(steps!) : nil,
            activeEnergyKcal: energy,
            weightKg: weight,
            bodyFatPct: bodyFat != nil ? bodyFat! * 100 : nil,
            exerciseMinutes: nil,
            respiratoryRate: resp,
            vo2Max: vo2
        )

        try await recoveryService.saveRecovery(recovery)
    }

    private func queryAverage(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .discreteAverage) { _, stats, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let value = stats?.averageQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func querySum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let value = stats?.sumQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func queryLatest(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sortDescriptor]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func querySleepHours(start: Date, end: Date) async throws -> Double? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let categorySamples = samples as? [HKCategorySample] else {
                    continuation.resume(returning: nil)
                    return
                }
                let asleepSamples = categorySamples.filter { sample in
                    sample.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue ||
                    sample.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue ||
                    sample.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue ||
                    sample.value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                }
                let totalSeconds = asleepSamples.reduce(0.0) { sum, sample in
                    sum + sample.endDate.timeIntervalSince(sample.startDate)
                }
                continuation.resume(returning: totalSeconds / 3600.0)
            }
            store.execute(query)
        }
    }
}
