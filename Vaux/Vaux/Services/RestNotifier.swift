// RestNotifier.swift
// Vaux
//
// Makes the end of a rest period reachable when the app isn't on screen.
//
// The in-app countdown is driven by a `Task.sleep` that fires a haptic when
// it wakes. That only works while the app is running: put the phone down
// mid-session and iOS locks the screen within seconds, suspends the app, and
// the sleeping task never resumes — the athlete comes back to a ring that
// expired at an unknown point. A local notification is scheduled with the
// system instead, so the alert is delivered by iOS whether or not Vaux is
// still executing.
//
// Both paths are always armed, and exactly one of them is allowed to speak:
// when the app *is* frontmost, `willPresent` suppresses the banner and the
// on-screen ring plus haptic does the job. The notification is the fallback
// for every other case.

import Foundation
import UIKit
import UserNotifications

/// One rest runs at a time, so a single identifier is enough — rescheduling
/// after an extend simply replaces the pending request.
///
/// Explicitly `nonisolated`: the target builds with default MainActor
/// isolation, which infers that onto file-level declarations too, putting this
/// out of reach of the non-isolated delegate below. Opting out is safe for an
/// immutable `let` of a Sendable type — there is nothing here to race on.
private nonisolated let restRequestID = "vaux.rest.complete"

final class RestNotifier {
    static let shared = RestNotifier()

    /// `UNUserNotificationCenter.delegate` is a weak reference, so this has to
    /// be owned somewhere that outlives the call to `start()`. The singleton is
    /// that owner; a delegate created inline would be released immediately and
    /// foreground suppression would silently stop working.
    private let presentationDelegate = RestPresentationDelegate()

    private var didRequestAuthorization = false

    private init() {}

    /// Installs the foreground-suppression delegate. Called once at launch;
    /// the delegate must be set before any notification could be delivered.
    func start() {
        UNUserNotificationCenter.current().delegate = presentationDelegate
    }

    // MARK: - Authorization

    /// Asked at the start of a workout rather than at launch: by then the
    /// athlete has opted into a session, so the prompt reads as part of that
    /// flow instead of arriving unexplained next to the HealthKit sheet. Safe
    /// to call repeatedly — iOS only shows the dialog once, and this drops
    /// repeat calls within a launch anyway.
    func requestAuthorizationIfNeeded() async {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            // A refusal is a legitimate choice, not an error state: the
            // in-app timer still works, it just can't reach a locked screen.
            print("[RestNotifier] Authorization failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Scheduling

    /// Schedules the rest-complete alert for `endDate`, replacing any pending
    /// one. `nextSet` is folded into the body so a glance at the Lock Screen
    /// says what to do, not just that time is up.
    func schedule(at endDate: Date, nextSet: String?) {
        let delay = endDate.timeIntervalSinceNow
        // A deadline already past has nothing to schedule — the in-app
        // completion path has it.
        guard delay > 0 else {
            cancel()
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = nextSet.map { "Next: \($0)" } ?? "Time for your next set."
        content.sound = .default
        // Rest ending is the definition of time-sensitive: it is useless a
        // few minutes later, and gym sessions are exactly when a Focus mode
        // is likely to be on. Requires the Time Sensitive Notifications
        // capability on the target; without it iOS quietly treats this as an
        // ordinary active notification.
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: restRequestID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        )

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [restRequestID])
        center.add(request)
    }

    /// Drops the pending alert and clears any already delivered. Called when
    /// rest is skipped, when the workout ends, and after the in-app timer
    /// completes on screen — otherwise a skipped rest would still buzz, and a
    /// completed one would leave a stale banner in Notification Centre.
    func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [restRequestID])
        center.removeDeliveredNotifications(withIdentifiers: [restRequestID])
    }
}

// MARK: - Foreground suppression

/// Decides what a delivered notification looks like while Vaux is frontmost.
private final class RestPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Returning no presentation options means: show nothing. With the app
    /// frontmost the countdown ring is already on screen and fires its own
    /// haptic, so a banner over it would be duplicate noise. Anything that
    /// isn't the rest alert keeps normal presentation.
    /// Explicitly `nonisolated`: the target builds with default MainActor
    /// isolation, which would otherwise infer this onto the main actor and put
    /// it at odds with the protocol's non-isolated requirement. It reads only an
    /// immutable identifier, so it needs no isolation.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.identifier == restRequestID ? [] : [.banner, .sound]
    }
}

// MARK: - Screen wake lock

/// Holds the screen awake for the length of a workout.
///
/// Auto-lock is measured in seconds of no touches, and a set plus its rest is
/// minutes of exactly that — so the screen would black out during the part of
/// the session the athlete most needs to see. Refcounted rather than a bare
/// bool so overlapping owners (the workout view and a presented sheet) can't
/// release each other's hold.
enum ScreenWakeLock {
    private static var holders = 0

    static func acquire() {
        holders += 1
        apply()
    }

    static func release() {
        holders = max(0, holders - 1)
        apply()
    }

    private static func apply() {
        UIApplication.shared.isIdleTimerDisabled = holders > 0
    }
}
