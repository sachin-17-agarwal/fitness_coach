// ExerciseCatalog.swift
// Vaux
//
// Lazy-loaded lookup from exercise name → muscle group, sourced from the
// Supabase `exercises` table. Used by the weekly-volume aggregation to
// bucket logged sets by the muscle group they trained.

import Foundation
import Observation

/// Row shape for the `exercises` table. Only the fields we care about.
private struct ExerciseRow: Decodable {
    let name: String
    let muscleGroup: String?
    let aliases: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case muscleGroup = "muscle_group"
        case aliases
    }
}

@Observable
final class ExerciseCatalog {
    static let shared = ExerciseCatalog()

    private(set) var isLoaded = false

    /// Lowercased exercise name (and aliases) → muscle group.
    /// Seeded with the built-in defaults so standard movements categorize
    /// even before the remote catalog loads (or when it's empty).
    private var lookup: [String: String] = ExerciseCatalog.builtinGroups

    /// Loads the catalog at most once per app run. Subsequent calls are
    /// no-ops. Safe to call repeatedly from view-model `load()` paths.
    func loadIfNeeded() async {
        guard !isLoaded else { return }
        do {
            let rows: [ExerciseRow] = try await SupabaseClient.shared.fetch("exercises")
            // Start from the built-in defaults and overlay the user's
            // remote catalog so explicit entries always win. The remote
            // `exercises` table ships empty (rows only appear via "add
            // exercise" in chat or the Exercise Library screen), so
            // without the built-ins every standard movement showed up
            // as "uncategorized" in the Volume tab.
            // Placeholder groups ("add exercise" defaults to "Unknown")
            // must not shadow a built-in mapping: an exercises-table row
            // named "machine calf press" with group Unknown would exact-
            // match before the built-in "calf press" → Calves ever ran,
            // and every set of it would drop out of the volume/strength
            // buckets.
            let placeholders: Set<String> = ["unknown", "other", "uncategorized", "n/a", "none", "tbd"]
            var map = Self.builtinGroups
            for row in rows {
                guard let group = row.muscleGroup, !group.isEmpty,
                      !placeholders.contains(group.lowercased()) else { continue }
                map[row.name.lowercased()] = group
                for alias in row.aliases ?? [] {
                    map[alias.lowercased()] = group
                }
            }
            lookup = map
            isLoaded = true
        } catch {
            print("[ExerciseCatalog] Load failed: \(error.localizedDescription)")
        }
    }

    /// Returns the muscle group for `exercise`, or `nil` if the catalog
    /// has no entry. Tries an exact lowercased lookup first, then a
    /// substring match against catalog keys (handles cases where the
    /// logged name has extra qualifiers like "incline barbell bench
    /// press" vs. catalog entry "bench press").
    ///
    /// Substring matching prefers the **longest** catalog key that fits,
    /// so "leg press" wins over "press" when both are present. Without
    /// this the dictionary iteration order would non-deterministically
    /// match a short generic key first.
    func muscleGroup(for exercise: String) -> String? {
        let key = PrescriptionParser.normalizeExerciseName(exercise).lowercased()
        if let direct = lookup[key] { return direct }

        var bestMatch: (length: Int, group: String)?
        for (catalogKey, group) in lookup where catalogKey.count >= 4 {
            // Only the `key.contains(catalogKey)` direction is safe:
            // a longer logged name with extra qualifiers ("incline
            // barbell bench press") should still match the catalog's
            // "bench press". The reverse ("bench" matching "bench
            // press") would mismatch when the user logs an abbrev.
            guard key.contains(catalogKey) else { continue }
            if bestMatch == nil || catalogKey.count > bestMatch!.length {
                bestMatch = (catalogKey.count, group)
            }
        }
        return bestMatch?.group
    }

    // MARK: - Bodyweight movements

    /// Movements loaded by the athlete's own bodyweight. A logged weight of 0
    /// on these is a complete set, not missing data — and a positive weight is
    /// load ADDED to bodyweight (a +10kg pull-up), never the total.
    ///
    /// Deliberately narrow: misclassifying a stack exercise here would render
    /// a plain 70kg set as "BW+70kg".
    private static let bodyweightMovements: [String] = [
        "pull-up", "pullup", "pull up",
        "chin-up", "chinup", "chin up",
        "muscle-up", "muscle up",
        "dip",
        "push-up", "pushup", "push up",
        "inverted row",
        "hanging leg raise", "hanging knee raise",
        "leg raise", "knee raise",
        "ab wheel", "rollout",
        "plank", "hollow hold",
        "nordic curl",
    ]

    /// True when `exercise` is loaded by bodyweight rather than by a stack.
    static func isBodyweight(_ exercise: String) -> Bool {
        let key = PrescriptionParser.normalizeExerciseName(exercise).lowercased()
        return bodyweightMovements.contains { key.contains($0) }
    }

    /// How a single set's load should read on screen and in coach messages.
    ///
    /// Bodyweight parses and persists as 0, so a plain "\(weight)kg" renders a
    /// hard set of dips as "0kg × 13" — which reads as a logging failure. And
    /// the 10kg on a weighted pull-up is added load, not the total, so showing
    /// "10kg × 6" understates the set. Tonnage and 1RM displays keep using
    /// `weightString`; this is only for per-set load.
    static func setWeightLabel(_ weight: Double, exercise: String) -> String {
        if weight <= 0 { return "BW" }
        if isBodyweight(exercise) { return "BW+\(weight.wholeOrOne)kg" }
        return weight.weightString
    }

    // MARK: - Built-in defaults

    /// Standard movements → muscle group, used as the floor under the
    /// remote catalog. Keys are lowercased; the substring matcher in
    /// `muscleGroup(for:)` extends each entry to qualified variants
    /// ("Incline Barbell Bench Press" → "bench press"), preferring the
    /// longest key, which is what disambiguates e.g. "leg curl" (Legs)
    /// from the generic "curl" (Biceps) and "reverse pec deck"
    /// (Rear Delts) from "pec deck" (Chest).
    ///
    /// Group names match the buckets WeeklyVolumeView knows targets for:
    /// Chest, Back, Shoulders, Rear Delts, Biceps, Triceps, Legs, Calves,
    /// Abs.
    private static let builtinGroups: [String: String] = [
        // Chest
        "bench press": "Chest",
        "incline press": "Chest",
        "incline bench": "Chest",
        // The matcher works on substrings, so "incline press" does not catch
        // "Incline Machine Press" — the qualifier sits between the two words.
        // Without these the sets resolve to no muscle group at all and drop
        // silently out of weekly volume, the same way "Single Leg Sumo Press"
        // once did.
        "incline machine press": "Chest",
        "incline dumbbell press": "Chest",
        "incline db press": "Chest",
        "incline barbell press": "Chest",
        "incline chest press": "Chest",
        "decline press": "Chest",
        "chest press": "Chest",
        "chest fly": "Chest",
        "pec fly": "Chest",
        "cable fly": "Chest",
        "cable crossover": "Chest",
        "pec deck": "Chest",
        "push-up": "Chest",
        "push-ups": "Chest",
        "push up": "Chest",
        "push ups": "Chest",
        "pushup": "Chest",
        "pushups": "Chest",
        "dips": "Chest",

        // Back
        "deadlift": "Back",
        "barbell row": "Back",
        "bent-over row": "Back",
        "bent over row": "Back",
        "pendlay row": "Back",
        "cable row": "Back",
        "seated row": "Back",
        "t-bar row": "Back",
        "t bar row": "Back",
        "dumbbell row": "Back",
        "machine row": "Back",
        "chest-supported row": "Back",
        "chest supported row": "Back",
        "inverted row": "Back",
        "low row": "Back",
        "high row": "Back",
        "lat pulldown": "Back",
        "pulldown": "Back",
        "pull-up": "Back",
        "pull-ups": "Back",
        "pull up": "Back",
        "pull ups": "Back",
        "pullup": "Back",
        "pullups": "Back",
        "chin-up": "Back",
        "chin-ups": "Back",
        "chin up": "Back",
        "chinup": "Back",
        "rack pull": "Back",
        "shrug": "Back",
        "shrugs": "Back",
        "back extension": "Back",

        // Shoulders
        "overhead press": "Shoulders",
        "shoulder press": "Shoulders",
        "military press": "Shoulders",
        "arnold press": "Shoulders",
        "push press": "Shoulders",
        "lateral raise": "Shoulders",
        "lateral raises": "Shoulders",
        "side raise": "Shoulders",
        "front raise": "Shoulders",
        "upright row": "Shoulders",

        // Rear delts
        "face pull": "Rear Delts",
        "face pulls": "Rear Delts",
        "rear delt": "Rear Delts",
        "rear delt fly": "Rear Delts",
        "rear delt raise": "Rear Delts",
        "reverse fly": "Rear Delts",
        "reverse cable fly": "Rear Delts",
        "reverse pec deck": "Rear Delts",

        // Biceps
        "curl": "Biceps",
        "bicep": "Biceps",
        "bicep curl": "Biceps",
        "biceps curl": "Biceps",
        "barbell curl": "Biceps",
        "dumbbell curl": "Biceps",
        "hammer curl": "Biceps",
        "preacher curl": "Biceps",
        "cable curl": "Biceps",
        "ez bar curl": "Biceps",
        "ez-bar curl": "Biceps",
        "concentration curl": "Biceps",
        "incline curl": "Biceps",
        "spider curl": "Biceps",

        // Triceps
        "tricep": "Triceps",
        "tricep pushdown": "Triceps",
        "triceps pushdown": "Triceps",
        "pushdown": "Triceps",
        "push-down": "Triceps",
        "tricep extension": "Triceps",
        "triceps extension": "Triceps",
        "overhead extension": "Triceps",
        // The substring matcher needs the exact phrasing: "Overhead Cable
        // Extension" does not contain "overhead extension" (the word
        // "cable" sits between them), so without these it resolves to no
        // muscle group and its sets vanish from the volume/strength tabs.
        "overhead cable extension": "Triceps",
        "overhead tricep": "Triceps",
        "overhead triceps": "Triceps",
        "cable overhead extension": "Triceps",
        "rope extension": "Triceps",
        "rope pushdown": "Triceps",
        "skull crusher": "Triceps",
        "skull crushers": "Triceps",
        "skullcrusher": "Triceps",
        "close grip bench": "Triceps",
        "close-grip bench": "Triceps",
        "tricep dip": "Triceps",
        "kickback": "Triceps",

        // Legs (quads, hamstrings, glutes share one volume bucket)
        "squat": "Legs",
        "leg press": "Legs",
        // "Single Leg Sumo Press" does NOT contain the substring "leg
        // press", so it matched nothing and every set of it was dropped
        // from the volume and strength buckets — the same silent-drop
        // failure as the calf work. Cover the stance/unilateral naming
        // variants explicitly.
        "sumo press": "Legs",
        "sumo leg press": "Legs",
        "single leg press": "Legs",
        "single-leg press": "Legs",
        "unilateral leg press": "Legs",
        "horizontal leg press": "Legs",
        "vertical leg press": "Legs",
        "45 degree leg press": "Legs",
        "leg extension": "Legs",
        "leg curl": "Legs",
        "leg curls": "Legs",
        "seated leg curl": "Legs",
        "lying leg curl": "Legs",
        "hamstring curl": "Legs",
        "nordic curl": "Legs",
        "romanian deadlift": "Legs",
        "stiff-leg deadlift": "Legs",
        "stiff leg deadlift": "Legs",
        "rdl": "Legs",
        "good morning": "Legs",
        "hip thrust": "Legs",
        "glute bridge": "Legs",
        "glute kickback": "Legs",
        "lunge": "Legs",
        "lunges": "Legs",
        "step-up": "Legs",
        "step-ups": "Legs",
        "step up": "Legs",
        "hip abduction": "Legs",
        "hip adduction": "Legs",
        "abductor": "Legs",
        "adductor": "Legs",

        // Calves — include the bare "calf"/"calves" catch-alls: "calf" is
        // NOT a substring of "calves", so plural-named variants ("Calves
        // Press", "Standing Calves Raise") matched nothing and their sets
        // silently vanished from the volume/strength buckets.
        "calf": "Calves",
        "calves": "Calves",
        "calf raise": "Calves",
        "calf raises": "Calves",
        "calf press": "Calves",
        "seated calf": "Calves",
        "standing calf": "Calves",
        "donkey calf": "Calves",
        "toe press": "Calves",

        // Abs
        "plank": "Abs",
        "crunch": "Abs",
        "crunches": "Abs",
        "cable crunch": "Abs",
        "sit-up": "Abs",
        "sit-ups": "Abs",
        "sit up": "Abs",
        "situp": "Abs",
        "leg raise": "Abs",
        "leg raises": "Abs",
        "knee raise": "Abs",
        "ab wheel": "Abs",
        "ab rollout": "Abs",
        "rollout": "Abs",
        "russian twist": "Abs",
        "dead bug": "Abs",
        "mountain climber": "Abs",
        "hollow hold": "Abs",
        "pallof press": "Abs",
    ]
}
