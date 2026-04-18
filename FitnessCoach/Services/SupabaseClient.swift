// SupabaseClient.swift
// FitnessCoach
//
// Lightweight Supabase REST client using PostgREST conventions.
// Avoids the Supabase Swift SDK so the project stays SPM-free for sideloading.

import Foundation

// MARK: - Errors

enum SupabaseError: LocalizedError {
    case invalidURL(String)
    case httpError(statusCode: Int, body: String)
    case decodingError(Error)
    case encodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid Supabase URL: \(url)"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .decodingError(let error):
            return "Decoding failed: \(error.localizedDescription)"
        case .encodingError(let detail):
            return "Encoding failed: \(detail)"
        }
    }
}

// MARK: - Client

final class SupabaseClient: Sendable {
    static let shared = SupabaseClient()

    private let baseURL: String
    private let apiKey: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    // MARK: Init

    init(
        baseURL: String = Config.supabaseURL,
        apiKey: String = Config.supabaseKey,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.session = session

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    // MARK: - Public API

    /// Fetch rows from a table.  Generic return decoded from JSON array.
    ///
    /// - Parameters:
    ///   - table: Supabase table name (e.g. `"recovery"`).
    ///   - query: PostgREST filter parameters, e.g. `["date": "eq.2026-04-18"]`.
    ///   - select: Columns to select (default `"*"`).
    ///   - order: Order clause, e.g. `"date.desc"`.
    ///   - limit: Maximum rows to return.
    func fetch<T: Decodable>(
        _ table: String,
        query: [String: String] = [:],
        select: String = "*",
        order: String? = nil,
        limit: Int? = nil
    ) async throws -> [T] {
        var params = query
        params["select"] = select
        if let order { params["order"] = order }
        if let limit { params["limit"] = String(limit) }

        let url = try buildURL(table: table, params: params)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        do {
            return try decoder.decode([T].self, from: data)
        } catch {
            throw SupabaseError.decodingError(error)
        }
    }

    /// Insert a row.  Returns raw response data.
    @discardableResult
    func insert(_ table: String, body: [String: Any]) async throws -> Data {
        let url = try buildURL(table: table)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try serializeJSON(body)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    /// Insert a row and decode the returned representation.
    func insertAndDecode<T: Decodable>(_ table: String, body: [String: Any]) async throws -> T {
        let data = try await insert(table, body: body)
        do {
            let rows = try decoder.decode([T].self, from: data)
            guard let first = rows.first else {
                throw SupabaseError.decodingError(
                    NSError(domain: "SupabaseClient", code: 0,
                            userInfo: [NSLocalizedDescriptionKey: "Insert returned empty array"])
                )
            }
            return first
        } catch let error as SupabaseError {
            throw error
        } catch {
            throw SupabaseError.decodingError(error)
        }
    }

    /// Upsert a row (insert or update on conflict).
    @discardableResult
    func upsert(_ table: String, body: [String: Any], onConflict: String) async throws -> Data {
        let url = try buildURL(table: table)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.setValue(
            "return=representation,resolution=merge-duplicates",
            forHTTPHeaderField: "Prefer"
        )
        request.setValue(onConflict, forHTTPHeaderField: "on-conflict")

        // PostgREST also accepts ?on_conflict= as a query param.
        // Using the header keeps the URL clean.
        request.httpBody = try serializeJSON(body)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    /// Update rows matching the given filters.
    @discardableResult
    func update(
        _ table: String,
        body: [String: Any],
        match: [String: String]
    ) async throws -> Data {
        var params: [String: String] = [:]
        for (key, value) in match {
            params[key] = "eq.\(value)"
        }

        let url = try buildURL(table: table, params: params)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        applyHeaders(to: &request)
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try serializeJSON(body)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    /// Delete rows matching the given filters.
    @discardableResult
    func delete(_ table: String, match: [String: String]) async throws -> Data {
        var params: [String: String] = [:]
        for (key, value) in match {
            params[key] = "eq.\(value)"
        }

        let url = try buildURL(table: table, params: params)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyHeaders(to: &request)
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    // MARK: - Helpers

    private func buildURL(
        table: String,
        params: [String: String] = [:]
    ) throws -> URL {
        let urlString = "\(baseURL)/rest/v1/\(table)"
        guard var components = URLComponents(string: urlString) else {
            throw SupabaseError.invalidURL(urlString)
        }
        if !params.isEmpty {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw SupabaseError.invalidURL(urlString)
        }
        return url
    }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw SupabaseError.httpError(statusCode: http.statusCode, body: body)
        }
    }

    private func serializeJSON(_ dict: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(dict) else {
            throw SupabaseError.encodingError("Dictionary is not valid JSON")
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }
}
