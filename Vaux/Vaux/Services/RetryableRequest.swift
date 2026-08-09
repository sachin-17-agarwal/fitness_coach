// RetryableRequest.swift
// Vaux
//
// Small retry helper for URLSession requests. Only retries network-level
// failures (URLError) — never HTTP 5xx, because the server may have
// already processed the write and a retry would double-log.
//
// The same reasoning divides the URLErrors themselves. "Couldn't resolve
// the host" proves nothing was delivered; "the connection dropped" and
// "it timed out" prove nothing at all — the server may have received the
// request in full and finished the work. Retrying the second kind against
// a non-idempotent endpoint duplicates it, which is what backgrounding
// the app mid-request used to do to the coach.

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
///
/// - Parameter idempotent: whether repeating this request is harmless.
///   `true` for reads. Pass `false` for any request that changes server
///   state, which restricts retries to failures that provably happened
///   before delivery.
func withRetry<T: Sendable>(
    maxAttempts: Int = 3,
    idempotent: Bool = true,
    attempt: @Sendable () async throws -> T
) async throws -> T {
    var lastError: Error?
    for attemptNumber in 1...maxAttempts {
        do {
            return try await attempt()
        } catch let urlError as URLError where shouldRetry(urlError, idempotent: idempotent) {
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

private func shouldRetry(_ error: URLError, idempotent: Bool) -> Bool {
    if failedBeforeDelivery(error) { return true }
    return idempotent && deliveryUnknown(error)
}

/// Failures where the request demonstrably never reached the server: the
/// host never resolved, no connection was established, or there was no
/// network to send it over. Nothing was processed, so a retry is safe no
/// matter what the request does.
private func failedBeforeDelivery(_ error: URLError) -> Bool {
    switch error.code {
    case .cannotFindHost, .cannotConnectToHost,
         .dnsLookupFailed, .notConnectedToInternet:
        return true
    default:
        return false
    }
}

/// Failures that say nothing about whether the server acted. A connection
/// that dropped after the request went out, or a wait that elapsed, both
/// look identical from here whether the server ignored it or completed it.
/// Backgrounding the app mid-request produces exactly these.
private func deliveryUnknown(_ error: URLError) -> Bool {
    switch error.code {
    case .timedOut, .networkConnectionLost, .resourceUnavailable:
        return true
    default:
        return false
    }
}
