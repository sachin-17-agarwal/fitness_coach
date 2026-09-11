// ReadinessStore.swift
// Vaux
//
// One tap at session start — how the athlete feels, 1 to 5 — kept for the day
// so every chat request carries it. Self-reported wellbeing tracks training
// load more sensitively than HRV or resting heart rate (Saw et al. 2016), and
// in the recovery read it is the signal that outranks the watch: a low tap
// lowers effort on its own, and a load cut needs the readings and the athlete
// to agree.

import Foundation

enum ReadinessStore {
    static let labels: [Int: String] = [1: "Wrecked", 2: "Rough", 3: "Okay", 4: "Good", 5: "Fresh"]

    private static var key: String { "readiness." + Config.isoDay() }

    static var today: Int? {
        get {
            let v = UserDefaults.standard.integer(forKey: key)
            return (1...5).contains(v) ? v : nil
        }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}
