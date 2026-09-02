// ChatHandoff.swift
// Vaux
//
// A one-slot mailbox for "ask the coach about this". A screen that has
// computed a diagnosis drops the question here and switches to the Coach
// tab; the chat view picks it up into its composer. The athlete still sends
// it — nothing is posted on their behalf.

import Foundation
import Observation

@Observable
final class ChatHandoff {
    static let shared = ChatHandoff()

    /// Text waiting to be placed in the composer, if any.
    var pendingPrompt: String?

    /// Takes the pending prompt, leaving the slot empty.
    func consume() -> String? {
        defer { pendingPrompt = nil }
        return pendingPrompt
    }
}
