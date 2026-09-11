// Keyboard.swift
// Vaux
//
// Dismiss the keyboard whatever field raised it.
//
// The "Done" over the keyboard belongs to the weight field's toolbar and used
// to clear only that field's focus. Type to the coach instead — the rest-screen
// composer, the Coach sheet — and the same Done appears, clears a flag that is
// already false, and the keyboard stays up. Resigning the first responder
// app-wide closes it for every field, so Done means done.

import UIKit

enum Keyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
