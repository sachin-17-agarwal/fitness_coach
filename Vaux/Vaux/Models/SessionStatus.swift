// SessionStatus.swift
// Vaux
//
// The lifecycle of a `workout_sessions` row.
//
// The column has two real states and four spellings in the table, because the
// two codebases picked their own from the start: this app wrote
// "in_progress"/"completed", the Python backend "active"/"complete". Nothing
// reconciled them, so a session ended in chat and one ended in the app read as
// different states — History rendered the first as unfinished, and its badge
// printed the raw string, so a finished workout showed up as "COMPLETE" in the
// styling reserved for one still running.
//
// New writes use one spelling per state. The old ones stay readable
// permanently rather than being migrated: the rows already in the table are
// the athlete's training history, and comparing against a normalised state is
// cheaper and safer than a migration. Mirrors the same constants in data.py.

import Foundation

enum SessionStatus {
    case open
    case finished

    /// The spelling new writes use, one per state.
    static let openStored = "in_progress"
    static let finishedStored = "completed"

    /// Every spelling that has ever meant each state. `openRawValues` is also
    /// what server-side filters have to enumerate, since PostgREST can't call
    /// into this type.
    static let openRawValues = ["in_progress", "active"]
    static let finishedRawValues = ["completed", "complete"]

    /// A PostgREST `in.(…)` filter matching any open spelling.
    static var openQueryFilter: String {
        "in.(\(openRawValues.joined(separator: ",")))"
    }

    /// Anything not recognised as finished counts as open. That direction is
    /// the safe one: an unknown value shows as in-progress and gets swept by
    /// the stale-session cleanup, whereas guessing "finished" would strand a
    /// live session with no way back into it.
    init(_ raw: String?) {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = Self.finishedRawValues.contains(value) ? .finished : .open
    }

    var isFinished: Bool { self == .finished }

    /// Badge text, derived from the state rather than echoed from the column —
    /// which is how "COMPLETE" and "COMPLETED" ended up on adjacent cards.
    var label: String { isFinished ? "COMPLETED" : "IN PROGRESS" }
}
