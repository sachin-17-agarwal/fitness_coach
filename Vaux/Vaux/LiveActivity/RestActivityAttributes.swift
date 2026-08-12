// RestActivityAttributes.swift
// Vaux
//
// Shared contract between the app and the widget extension. Both targets
// compile this file — if only one does, the activity starts and then renders
// as a blank capsule, because the system cannot decode a state it has no type
// for.
//
// Everything that changes during a session lives in ContentState, and only
// `sessionType` is fixed in the attributes. That split is deliberate: an
// activity's attributes are immutable for its lifetime, so putting the
// exercise name there would force us to end and re-request an activity at
// every machine. ActivityKit rate-limits requests, and a session moves through
// six exercises — reusing one activity for the whole workout keeps us well
// inside the budget.

import ActivityKit
import Foundation

struct RestActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When the rest began. Sent so the widget can draw a progress bar
        /// without us pushing an update per second — `ProgressView(timerInterval:)`
        /// interpolates between the two dates on its own.
        var startDate: Date

        /// The absolute deadline. Rendered with `Text(timerInterval:)`, which
        /// iOS ticks itself. This is the whole reason the countdown stays live
        /// while the app is suspended, and why the controller only ever pushes
        /// an update on start, extend and finish rather than every second.
        var endDate: Date

        /// The exercise being rested for.
        var exercise: String

        /// Two-line "what's next" summary from the prescription card, so the
        /// athlete can read the upcoming target without unlocking.
        var nextUp: String?

        /// Set when the rest has run out. The widget cannot flip this itself —
        /// `isStale` covers the case where the app never came back — but when
        /// the app *is* alive it marks completion explicitly so the island
        /// reads "Go" rather than a countdown frozen at zero.
        var isComplete: Bool

        var duration: TimeInterval { max(1, endDate.timeIntervalSince(startDate)) }
    }

    /// Pull / Push / Legs / Cardio+Abs. Fixed for the session.
    var sessionType: String
}
