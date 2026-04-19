// PrescriptionParser.swift
// FitnessCoach
//
// Parses Claude's workout response text into structured exercise prescriptions.
//
// Expected format from the AI:
//
//   *Machine Chest Press*
//   Warm-up: 85kg x10, 110kg x6
//   Working Set: 125kg x8 RPE8 | Tempo: 3-1-2 | Rest: 2min
//   Back-off: 100kg x12 RPE7
//   Form: Full ROM, control the negative.

import Foundation

// MARK: - Model

/// A single parsed exercise prescription from the AI's response.
struct ExercisePrescription: Identifiable, Sendable {
    var id = UUID()
    var exerciseName: String
    var warmupSets: [(weight: Double, reps: Int)]
    var workingSets: [(weight: Double, reps: Int, rpe: Double?)]
    var backoffSets: [(weight: Double, reps: Int, rpe: Double?)]
    var formCue: String?
    var tempo: String?
    var restSeconds: Int?

    var targetWeightKg: Double? { workingSets.first?.weight }
    var targetReps: Int? { workingSets.first?.reps }
    var targetRpe: Double? { workingSets.first?.rpe }
}

// MARK: - Parser

final class PrescriptionParser {

    // MARK: - Public

    /// Parses a full AI response string into an array of exercise prescriptions.
    /// Filters out "header" blocks that have no actual sets (e.g. session titles).
    static func parse(_ text: String) -> [ExercisePrescription] {
        let blocks = splitIntoExerciseBlocks(text)
        return blocks.compactMap { parseBlock($0) }
            .filter { !$0.warmupSets.isEmpty || !$0.workingSets.isEmpty || !$0.backoffSets.isEmpty }
    }

    // MARK: - Block splitting

    /// Splits the text into blocks, each starting with a bold exercise name.
    /// Supports both `*Name*` and `**Name**` markdown styles.
    private static func splitIntoExerciseBlocks(_ text: String) -> [String] {
        // Pattern: line starting with * or ** followed by exercise name and closing * or **
        let pattern = #"(?m)^[ \t]*\*{1,2}[^*\n]+\*{1,2}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        guard !matches.isEmpty else { return [] }

        var blocks: [String] = []
        for (i, match) in matches.enumerated() {
            let start = match.range.location
            let end: Int
            if i + 1 < matches.count {
                end = matches[i + 1].range.location
            } else {
                end = nsText.length
            }
            let block = nsText.substring(with: NSRange(location: start, length: end - start))
            blocks.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return blocks
    }

    // MARK: - Single block parsing

    private static func parseBlock(_ block: String) -> ExercisePrescription? {
        let rawLines = block.components(separatedBy: .newlines)
        guard let firstLine = rawLines.first else { return nil }

        // Extract exercise name from bold markers
        guard let name = extractExerciseName(firstLine) else { return nil }

        // The first line may contain content after the bold name, e.g.:
        // "*Machine Chest Press* Warm-up: 70kg x10, 100kg x6"
        // Extract the tail and treat it as an additional line.
        var lines = Array(rawLines.dropFirst())
        let tail = extractAfterBoldMarker(firstLine)
        if !tail.isEmpty {
            lines.insert(tail, at: 0)
        }

        var warmup: [(weight: Double, reps: Int)] = []
        var working: [(weight: Double, reps: Int, rpe: Double?)] = []
        var backoff: [(weight: Double, reps: Int, rpe: Double?)] = []
        var formCue: String?
        var tempo: String?
        var restSeconds: Int?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            if lower.hasPrefix("warm-up:") || lower.hasPrefix("warmup:") || lower.hasPrefix("warm up:") {
                let content = extractAfterColon(trimmed)
                warmup = parseWarmupSets(content)
            } else if lower.hasPrefix("working set:") || lower.hasPrefix("working sets:") || lower.hasPrefix("work:") {
                let content = extractAfterColon(trimmed)
                let (sets, rest, parsedTempo) = parseWorkingSets(content)
                working = sets
                if let r = rest { restSeconds = r }
                if let t = parsedTempo { tempo = t }
            } else if lower.hasPrefix("back-off:") || lower.hasPrefix("backoff:") || lower.hasPrefix("back off:") {
                let content = extractAfterColon(trimmed)
                let (sets, _, _) = parseWorkingSets(content)
                backoff = sets
            } else if lower.hasPrefix("form:") || lower.hasPrefix("form cue:") || lower.hasPrefix("cue:") {
                formCue = extractAfterColon(trimmed)
            } else if lower.hasPrefix("tempo:") {
                tempo = extractAfterColon(trimmed)
            } else if lower.hasPrefix("rest:") {
                let content = extractAfterColon(trimmed)
                restSeconds = parseRestSeconds(content)
            }
        }

        return ExercisePrescription(
            exerciseName: name,
            warmupSets: warmup,
            workingSets: working,
            backoffSets: backoff,
            formCue: formCue,
            tempo: tempo,
            restSeconds: restSeconds
        )
    }

    // MARK: - Name extraction

    /// Extracts the exercise name from a bold-marked line.
    /// Handles `*Name*`, `**Name**`, and leading emoji/bullet characters.
    private static func extractExerciseName(_ line: String) -> String? {
        let pattern = #"\*{1,2}([^*]+)\*{1,2}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: line,
                  range: NSRange(location: 0, length: (line as NSString).length)
              ),
              match.numberOfRanges > 1 else {
            return nil
        }
        let nameRange = match.range(at: 1)
        let name = (line as NSString).substring(with: nameRange)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: - Set parsing

    /// Parses warm-up sets from a string like "85kg x10, 110kg x6".
    /// Returns an array of (weight, reps) tuples.
    private static func parseWarmupSets(_ text: String) -> [(weight: Double, reps: Int)] {
        let segments = text.components(separatedBy: ",")
        return segments.compactMap { segment in
            let cleaned = segment.trimmingCharacters(in: .whitespaces)
            guard let (weight, reps) = parseWeightReps(cleaned) else { return nil }
            return (weight, reps)
        }
    }

    /// Parses working/back-off sets from a string like
    /// "125kg x8 RPE8 | Tempo: 3-1-2 | Rest: 2min".
    /// Handles pipe-separated metadata.  Returns (sets, optional rest, optional tempo).
    private static func parseWorkingSets(
        _ text: String
    ) -> (sets: [(weight: Double, reps: Int, rpe: Double?)], rest: Int?, tempo: String?) {
        let parts = text.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var rest: Int?
        var tempo: String?

        for part in parts {
            let lower = part.lowercased()
            if lower.hasPrefix("rest:") || lower.hasPrefix("rest ") {
                let content = part.contains(":") ? extractAfterColon(part) : part
                rest = parseRestSeconds(content)
            } else if lower.hasPrefix("tempo:") || lower.hasPrefix("tempo ") {
                tempo = part.contains(":") ? extractAfterColon(part) : String(part.dropFirst(6))
                tempo = tempo?.trimmingCharacters(in: .whitespaces)
            }
        }

        // The first part (before any pipe) contains the set prescription(s)
        guard let setsPart = parts.first else { return ([], rest, tempo) }

        let segments = setsPart.components(separatedBy: ",")
        let sets: [(weight: Double, reps: Int, rpe: Double?)] = segments.compactMap { segment in
            let cleaned = segment.trimmingCharacters(in: .whitespaces)
            guard let (weight, reps) = parseWeightReps(cleaned) else { return nil }
            let rpe = parseRPE(cleaned)
            return (weight, reps, rpe)
        }

        return (sets, rest, tempo)
    }

    /// Extracts weight and reps from strings like "125kg x8", "125 x 8",
    /// "125kgx8", "125 kg x 8".
    private static func parseWeightReps(_ text: String) -> (weight: Double, reps: Int)? {
        // Pattern: number (optional "kg"/"lbs") then "x" then number
        let pattern = #"(\d+(?:\.\d+)?)\s*(?:kg|lbs?)?\s*[xX×]\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(location: 0, length: (text as NSString).length)
              ),
              match.numberOfRanges > 2 else {
            return nil
        }
        let weightStr = (text as NSString).substring(with: match.range(at: 1))
        let repsStr = (text as NSString).substring(with: match.range(at: 2))
        guard let weight = Double(weightStr), let reps = Int(repsStr) else { return nil }
        return (weight, reps)
    }

    /// Extracts RPE from a string like "RPE8", "RPE 8.5", "@8".
    private static func parseRPE(_ text: String) -> Double? {
        let pattern = #"(?:RPE\s*|@)(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(location: 0, length: (text as NSString).length)
              ),
              match.numberOfRanges > 1 else {
            return nil
        }
        let rpeStr = (text as NSString).substring(with: match.range(at: 1))
        return Double(rpeStr)
    }

    /// Parses rest time from strings like "2min", "90s", "2 min", "90 seconds", "2:00".
    private static func parseRestSeconds(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()

        // Try "M:SS" format first (e.g. "2:00", "1:30")
        let colonPattern = #"(\d+):(\d{2})"#
        if let regex = try? NSRegularExpression(pattern: colonPattern),
           let match = regex.firstMatch(
               in: trimmed,
               range: NSRange(location: 0, length: (trimmed as NSString).length)
           ),
           match.numberOfRanges > 2 {
            let mins = (trimmed as NSString).substring(with: match.range(at: 1))
            let secs = (trimmed as NSString).substring(with: match.range(at: 2))
            if let m = Int(mins), let s = Int(secs) {
                return m * 60 + s
            }
        }

        // Try minutes: "2min", "2 min", "2 minutes"
        let minPattern = #"(\d+(?:\.\d+)?)\s*min"#
        if let regex = try? NSRegularExpression(pattern: minPattern),
           let match = regex.firstMatch(
               in: trimmed,
               range: NSRange(location: 0, length: (trimmed as NSString).length)
           ),
           match.numberOfRanges > 1 {
            let val = (trimmed as NSString).substring(with: match.range(at: 1))
            if let mins = Double(val) {
                return Int(mins * 60)
            }
        }

        // Try seconds: "90s", "90 seconds", "90sec"
        let secPattern = #"(\d+)\s*(?:s(?:ec(?:onds?)?)?)$"#
        if let regex = try? NSRegularExpression(pattern: secPattern),
           let match = regex.firstMatch(
               in: trimmed,
               range: NSRange(location: 0, length: (trimmed as NSString).length)
           ),
           match.numberOfRanges > 1 {
            let val = (trimmed as NSString).substring(with: match.range(at: 1))
            return Int(val)
        }

        // Bare number -- assume seconds if < 10, minutes otherwise
        if let num = Int(trimmed) {
            return num < 10 ? num * 60 : num
        }

        return nil
    }

    // MARK: - Utility

    /// Returns the substring after the first colon, trimmed.
    private static func extractAfterColon(_ text: String) -> String {
        guard let colonIndex = text.firstIndex(of: ":") else { return text }
        return String(text[text.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Returns text after the closing bold marker(s) on a line.
    /// e.g. "*Machine Chest Press* Warm-up: 70kg x10" → "Warm-up: 70kg x10"
    private static func extractAfterBoldMarker(_ line: String) -> String {
        let pattern = #"\*{1,2}[^*]+\*{1,2}\s*(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: line,
                  range: NSRange(location: 0, length: (line as NSString).length)
              ),
              match.numberOfRanges > 1 else {
            return ""
        }
        return (line as NSString).substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Extracts the narrative (non-structured) parts of an AI response:
    /// everything that isn't a bold exercise header, Warm-up/Working/Back-off/Form/Rest line.
    static func extractCoachNote(_ text: String) -> String? {
        let structuredPrefixes = [
            "warm-up:", "warmup:", "warm up:",
            "working set:", "working sets:", "work:",
            "back-off:", "backoff:", "back off:",
            "form:", "form cue:", "cue:",
            "rest:", "tempo:",
        ]
        let lines = text.components(separatedBy: "\n")
        var narrative: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Skip bold exercise headers
            if trimmed.hasPrefix("*") && trimmed.contains("*") {
                let afterBold = extractAfterBoldMarker(trimmed)
                let lower = afterBold.lowercased()
                let isStructured = structuredPrefixes.contains { lower.hasPrefix($0) }
                if isStructured || afterBold.isEmpty { continue }
            }

            let lower = trimmed.lowercased()
            let isStructured = structuredPrefixes.contains { lower.hasPrefix($0) }
            if isStructured { continue }

            narrative.append(trimmed)
        }

        let result = narrative.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }
}
