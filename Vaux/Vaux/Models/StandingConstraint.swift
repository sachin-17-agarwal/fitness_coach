// StandingConstraint.swift
// Vaux
//
// A `Decision:` the coach recorded in chat and the programme respects: a
// machine's top plate, a lift held at a load for a niggle. Stored by the
// backend in `exercise_constraints`; read here so the Strength tab can say a
// lift is HELD on purpose instead of calling its flat line a drop.

import Foundation

struct StandingConstraint: Codable, Hashable, Sendable {
    let exercise: String
    let maxLoadKg: Double?
    let note: String?
    let setOn: String

    enum CodingKeys: String, CodingKey {
        case exercise
        case maxLoadKg = "max_load_kg"
        case note
        case setOn = "set_on"
    }

    /// "13 SEP" from the ISO date the decision was recorded on.
    var sinceLabel: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: setOn) else { return setOn.uppercased() }
        let out = DateFormatter(); out.dateFormat = "d MMM"; out.locale = Locale(identifier: "en_US_POSIX")
        return out.string(from: d).uppercased()
    }

    /// "CAP 70 KG · SINCE 13 SEP", or just the date when no load is capped.
    var eyebrowDetail: String {
        (maxLoadKg.map { String(format: "CAP %g KG · ", $0) } ?? "") + "SINCE \(sinceLabel)"
    }
}
