// ReadinessScoreTests.swift
// VauxTests
//
// The readiness score the Home tab shows and the widget reads from the
// server. The anchors below are the ones readiness.py pins on the backend;
// the two formulas must agree to the point, so a change to either has to
// break a test on both sides.

import Testing
@testable import Vaux

@MainActor
struct ReadinessScoreTests {

    @Test func sleepAnchorsMatchTheServer() {
        #expect(Recovery.sleepComponent(hours: 8.5) == 100)
        #expect(Recovery.sleepComponent(hours: 8.0) == 100)
        #expect(Recovery.sleepComponent(hours: 7.5) == 92)
        #expect(Recovery.sleepComponent(hours: 7.0) == 82)
        #expect(Recovery.sleepComponent(hours: 6.0) == 58)
        #expect(Recovery.sleepComponent(hours: 5.0) == 32)
        #expect(Recovery.sleepComponent(hours: 4.0) == 15)
        #expect(Recovery.sleepComponent(hours: 3.0) == 5)
        #expect(Recovery.sleepComponent(hours: 2.0) == 3)
    }

    @Test func hrvAndRestingHeartRateAnchorsMatchTheServer() {
        #expect(Recovery.hrvComponent(ratio: 1.10) == 100)
        #expect(Recovery.hrvComponent(ratio: 1.00) == 85)
        #expect(Recovery.hrvComponent(ratio: 0.90) == 65)
        #expect(Recovery.hrvComponent(ratio: 0.50) == 5)
        #expect(Recovery.rhrComponent(ratio: 0.90) == 100)
        #expect(Recovery.rhrComponent(ratio: 1.00) == 85)
        #expect(Recovery.rhrComponent(ratio: 1.05) == 65)
        #expect(Recovery.rhrComponent(ratio: 1.20) == 10)
    }

    @Test func compositeWeightsAndRenormalisation() {
        // 7h sleep (82) × 0.4 + HRV on baseline (85) × 0.4 + RHR on baseline (85) × 0.2 = 83.8 → 84
        let full = Fixtures.recovery("2026-09-18", sleep: 7.0, hrv: 68, rhr: 52)
        #expect(full.compositeScore(hrv7DayAvg: 68, rhr7DayAvg: 52) == 84)
        // Sleep alone: the other weights drop out and the score is the sleep component.
        let sleepOnly = Fixtures.recovery("2026-09-18", sleep: 7.0)
        #expect(sleepOnly.compositeScore(hrv7DayAvg: nil, rhr7DayAvg: nil) == 82)
        // A weigh-in only row has no score at all.
        let weighIn = Fixtures.recovery("2026-09-18", weight: 80.8)
        #expect(weighIn.compositeScore(hrv7DayAvg: 68, rhr7DayAvg: 52) == nil)
    }

    @Test func todaysAmberRead() {
        // 18 Sep: sleep 5:55, HRV 40 on a ~40 baseline, RHR on baseline → amber, as the widget showed.
        let row = Fixtures.recovery("2026-09-18", sleep: 5.92, hrv: 40, rhr: 52)
        let score = row.compositeScore(hrv7DayAvg: 40, rhr7DayAvg: 52)
        #expect(score != nil)
        #expect(DashboardViewModel.level(for: score) == .yellow)
    }

    @Test func zonesAreTheHomeTabs() {
        #expect(DashboardViewModel.level(for: 75) == .green)
        #expect(DashboardViewModel.level(for: 74) == .yellow)
        #expect(DashboardViewModel.level(for: 55) == .yellow)
        #expect(DashboardViewModel.level(for: 54) == .red)
        #expect(DashboardViewModel.level(for: nil) == .unknown)
    }
}
