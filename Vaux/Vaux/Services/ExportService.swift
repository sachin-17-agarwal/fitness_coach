// ExportService.swift
// Vaux
//
// Every table the training log lives in, as CSV files in a dated folder,
// for the share sheet. Six months of logged training exists in one Supabase
// project; this is the copy the athlete owns, and the file any analysis
// outside the app starts from. Read-only.

import Foundation

struct ExportResult: Sendable {
    let folder: URL
    let files: [URL]
    let rowCounts: [String: Int]
}

@MainActor
final class ExportService {
    /// The numeric record. Chat history is deliberately not included: the
    /// export is for sharing numbers, not conversations.
    static let tables: [(name: String, order: String)] = [
        ("workout_sessions", "date.asc,id.asc"),
        ("workout_sets", "date.asc,id.asc"),
        ("recovery", "date.asc,id.asc"),
        ("exercise_constraints", "set_on.asc,id.asc"),
        ("prescription_decisions", "date.asc,id.asc"),
    ]

    private let client = SupabaseClient.shared

    /// Writes one CSV per table and returns their URLs. `progress` is called
    /// with the table being read, for the status line.
    func exportAll(progress: @escaping @MainActor (String) -> Void) async throws -> ExportResult {
        let day = Config.isoDay()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vaux-export-\(day)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        var counts: [String: Int] = [:]
        for (table, order) in Self.tables {
            progress(table)
            let rows = try await allRows(table, order: order)
            let url = folder.appendingPathComponent("\(table).csv")
            try Self.csv(rows).write(to: url, atomically: true, encoding: .utf8)
            files.append(url)
            counts[table] = rows.count
        }
        return ExportResult(folder: folder, files: files, rowCounts: counts)
    }

    private func allRows(_ table: String, order: String) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var offset = 0
        let page = 1000
        while true {
            let data = try await client.fetchRawPage(table, order: order, offset: offset, pageSize: page)
            let chunk = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            rows.append(contentsOf: chunk)
            if chunk.count < page { return rows }
            offset += page
        }
    }

    /// RFC 4180: every column the rows carry, `date` and `id` first, quotes
    /// doubled, fields with commas, quotes or newlines quoted. Nested JSON
    /// (a stored plan) is written as one JSON string.
    static func csv(_ rows: [[String: Any]]) -> String {
        var keys = Set<String>()
        for r in rows { keys.formUnion(r.keys) }
        let lead = ["date", "id"].filter { keys.contains($0) }
        let columns = lead + keys.subtracting(lead).sorted()
        var out = columns.map(quote).joined(separator: ",") + "\n"
        for r in rows {
            out += columns.map { quote(cell(r[$0])) }.joined(separator: ",") + "\n"
        }
        return out
    }

    private static func cell(_ value: Any?) -> String {
        switch value {
        case nil: return ""
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case is NSNull: return ""
        default:
            if let value, JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8) { return s }
            return String(describing: value ?? "")
        }
    }

    private static func quote(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
