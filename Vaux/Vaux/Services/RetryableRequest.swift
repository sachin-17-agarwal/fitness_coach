// RetryableRequest.swift
// Vaux
//
// Small retry helper for URLSession requests. Only retries network-level
// failures (URLError) — never HTTP 5xx, because the server may have
// already processed the write and a retry would double-log.

import Foundation

enum RetryConfig {
    /// Default attempts including the first try. 3 means: try, wait 1s,
    /// retry, wait 2s, retry, then give up.
    static let defaultMaxAttempts = 3

    /// Default per-request timeout for non-LLM Supabase calls. The
    /// URLSession default is 60s which is much too patient for REST
    /// reads that normally complete in <500ms.
    static let defaultTimeout: TimeInterval = 30

    /// Timeout for LLM-backed chat calls — Claude responses occasionally
    /// take 30-50s on long prompts, so we leave headroom.
    static let chatTimeout: TimeInterval = 60
}

enum RetryableRequestError: LocalizedError {
    case allAttemptsFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .allAttemptsFailed(let err):
            return "Request failed after retries: \(err.localizedDescription)"
        }
    }
}

/// Execute `attempt` up to `maxAttempts` times with exponential backoff.
/// Retries only on URLError (network-level failures). All other errors —
/// including HTTP 4xx/5xx that the caller surfaces as a typed error — are
/// rethrown immediately because retrying a write the server already
/// committed would duplicate data.
func withRetry<T: Sendable>(
    maxAttempts: Int = 3,
    attempt: @Sendable () async throws -> T
) async throws -> T {
    var lastError: Error?
    for attemptNumber in 1...maxAttempts {
        do {
            return try await attempt()
        } catch let urlError as URLError where isTransient(urlError) {
            lastError = urlError
            if attemptNumber == maxAttempts { break }
            let backoffSeconds = pow(2.0, Double(attemptNumber - 1))
            try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
        } catch {
            throw error
        }
    }
    throw RetryableRequestError.allAttemptsFailed(
        underlying: lastError ?? URLError(.unknown)
    )
}

private func isTransient(_ error: URLError) -> Bool {
    switch error.code {
    case .timedOut, .cannotFindHost, .cannotConnectToHost,
         .networkConnectionLost, .dnsLookupFailed,
         .notConnectedToInternet, .resourceUnavailable:
        return true
    default:
        return false
    }
}
