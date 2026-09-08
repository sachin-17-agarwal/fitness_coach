// BodyweightLoad.swift
// Vaux
//
// What a set of a bodyweight movement actually lifted.
//
// The logged weight on dips, pull-ups and hanging leg raises is the plate
// added to the athlete — 0 for a plain set, 19 for BW+19kg. Every total
// built on that number scored a back-off of bodyweight × 13 as nothing and
// last time's +5 × 10 as fifty kilos, when the first was about 1,050kg of
// work and the second about 860. The estimated 1RM had the same hole, so a
// move from +15 to +19 read as +27% strength on a lift that had gained about
// 4%. The athlete's own weight is most of the load; this puts it back.
//
// The share of bodyweight a movement moves is a convention, not a
// measurement: the whole body hangs from a bar or rests on the dip handles;
// a hanging leg raise moves roughly the legs, about a third of body mass.
// Rollouts, planks and holds have no meaningful load and are left as the
// plate alone. Machine and cable lifts are untouched.

import Foundation

enum BodyweightLoad {
    /// Fraction of bodyweight a movement lifts, nil for stack and cable lifts
    /// and for bodyweight movements with no meaningful load.
    static func fraction(for exercise: String) -> Double? {
        let key = PrescriptionParser.normalizeExerciseName(exercise).lowercased()
        if key.contains("machine") || key.contains("assisted") { return nil }
        if ["pull-up", "pullup", "pull up", "chin-up", "chinup", "chin up",
            "muscle-up", "muscle up", "dip", "push-up", "pushup", "push up",
            "inverted row"].contains(where: { key.contains($0) }) { return 1.0 }
        if ["hanging leg raise", "hanging knee raise", "leg raise", "knee raise"]
            .contains(where: { key.contains($0) }) { return 0.35 }
        if key.contains("nordic") { return 0.4 }
        return nil
    }

    /// The load a set moved: the plate plus the movement's share of the
    /// athlete's weight. With no weigh-in on record, the plate alone — never
    /// a guessed body.
    static func effective(_ added: Double, exercise: String, bodyweight: Double?) -> Double {
        guard let f = fraction(for: exercise), let bw = bodyweight, bw > 0 else { return added }
        return added + bw * f
    }
}

/// The athlete's weigh-ins, so a set is scored against the body that lifted
/// it: 76.5kg in July, 80.5kg now. A day without a weigh-in takes the most
/// recent one before it.
struct WeighInRecord: Sendable {
    /// (yyyy-MM-dd, kg), ascending by date.
    let entries: [(date: String, kg: Double)]

    static let empty = WeighInRecord(entries: [])

    init(entries: [(date: String, kg: Double)]) {
        self.entries = entries.sorted { $0.date < $1.date }
    }

    /// Weight on or before `date`; the earliest weigh-in when `date` precedes
    /// them all; nil only with no weigh-ins at all.
    func kg(on date: String?) -> Double? {
        guard let date, !entries.isEmpty else { return latest }
        var best: Double?
        for e in entries {
            if e.date <= date { best = e.kg } else { break }
        }
        return best ?? entries.first?.kg
    }

    var latest: Double? { entries.last?.kg }
}
