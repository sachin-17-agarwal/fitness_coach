// RecoveryDigestTests.swift
// VauxTests
//
// The Monday/Tuesday card under the Home ledger: built from rows, no model.

import Foundation
import Testing
@testable import Vaux

@MainActor
struct RecoveryDigestTests {

    /// Seven mornings ending Sunday 13 Sep 2026, plus a thin baseline.
    private var rows: [Recovery] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let sunday = Fixtures.date("2026-09-13")
        var out: [Recovery] = []
        for back in 0..<49 {
            let d = Calendar.current.date(byAdding: .day, value: -back, to: sunday)!
            out.append(Fixtures.recovery(f.string(from: d), sleep: 7.2 - Double(back % 3) * 0.4,
                                         hrv: 60 + Double(back % 5), rhr: 52, weight: 80.5))
        }
        return out
    }

    @Test func nothingOnAWednesday() {
        // 16 Sep 2026 is a Wednesday.
        #expect(RecoveryDigest.build(rows: rows, today: Fixtures.date("2026-09-16")) == nil)
    }

    @Test func onMondayTheWeekJustGoneIsRead() throws {
        // 14 Sep 2026 is a Monday; the week read is 7–13 Sep.
        let digest = try #require(RecoveryDigest.build(rows: rows, today: Fixtures.date("2026-09-14")))
        #expect(!digest.sentences.isEmpty)
        #expect(digest.sentences.count <= 3)
        #expect(!digest.rangeLabel.isEmpty)
        #expect(digest.sentences.joined(separator: " ").contains("HRV"))
    }

    @Test func anEmptyWeekHasNoDigest() {
        // Rows only from long before the week in question.
        let old = rows.filter { $0.date < "2026-08-20" }
        #expect(RecoveryDigest.build(rows: old, today: Fixtures.date("2026-09-14")) == nil)
    }
}
