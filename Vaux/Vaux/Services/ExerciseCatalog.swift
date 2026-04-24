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
    private var lookup: [String: String] = [:]

    /// Loads the catalog at most once per app run. Subsequent calls are
    /// no-ops. Safe to call repeatedly from view-model `load()` paths.
    func loadIfNeeded() async {
        guard !isLoaded else { return }
        do {
            let rows: [ExerciseRow] = try await SupabaseClient.shared.fetch("exercises")
            var map: [String: String] = [:]
            for row in rows {
                guard let group = row.muscleGroup, !group.isEmpty else { continue }
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
    func muscleGroup(for exercise: String) -> String? {
        let key = PrescriptionParser.normalizeExerciseName(exercise).lowercased()
        if let direct = lookup[key] { return direct }
        for (catalogKey, group) in lookup where key.contains(catalogKey) || catalogKey.contains(key) {
            return group
        }
        return nil
    }
}
