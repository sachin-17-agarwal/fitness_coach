// Date+Formatting.swift
// FitnessCoach

import Foundation

extension Date {
    // MARK: - Shared Formatters

    private static let sydneyTimeZone = TimeZone(identifier: "Australia/Sydney")!

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = sydneyTimeZone
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = sydneyTimeZone
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = sydneyTimeZone
        return formatter
    }()

    // MARK: - Computed Properties

    /// The date as `yyyy-MM-dd` in Australia/Sydney timezone (e.g. "2026-04-18").
    var localDateString: String {
        Self.dateFormatter.string(from: self)
    }

    /// The time as `HH:mm` in Australia/Sydney timezone (e.g. "14:30").
    var timeString: String {
        Self.timeFormatter.string(from: self)
    }

    /// A human-friendly string: "Today", "Yesterday", or a medium-format date.
    var relativeString: String {
        var calendar = Calendar.current
        calendar.timeZone = Self.sydneyTimeZone

        let todayString = Date().localDateString
        let selfString = self.localDateString

        if selfString == todayString {
            return "Today"
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()),
           selfString == yesterday.localDateString {
            return "Yesterday"
        }

        return Self.displayDateFormatter.string(from: self)
    }
}
