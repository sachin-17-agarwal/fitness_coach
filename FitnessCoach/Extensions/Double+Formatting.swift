// Double+Formatting.swift
// FitnessCoach

import Foundation

extension Double {
    /// Formatted to one decimal place (e.g. 7.2).
    var oneDecimal: String {
        String(format: "%.1f", self)
    }

    /// Shows one decimal place only when the fractional part is non-zero.
    /// e.g. 100.0 -> "100", 100.5 -> "100.5"
    var wholeOrOne: String {
        truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", self)
            : String(format: "%.1f", self)
    }

    /// A weight display string with "kg" suffix.
    /// e.g. 100.0 -> "100kg", 100.5 -> "100.5kg"
    var weightString: String {
        "\(wholeOrOne)kg"
    }
}
