// RestActivityController.swift
// Vaux
//
// Keeps the rest countdown on the Lock Screen and in the Dynamic Island while
// the athlete is doing something else with the phone.
//
// This is the third path to the same deadline, and it is worth being clear
// about why all three exist:
//
//   RestTimer's .task   — the on-screen ring. Dies when iOS suspends the app.
//   RestNotifier        — a scheduled alert. Fires once, at the end.
//   this                — a live countdown, visible without unlocking.
//
// The notification tells you rest is over. The Live Activity tells you how
// long is left, which is the thing you actually want when you have put the
// phone down and are watching the rack.
//
// ── The one rule that governs this file ──────────────────────────────────
// ActivityKit budgets updates, and an activity that burns its budget stops
// updating for the rest of its life. So we never push a per-second tick. The
// state carries `startDate` and `endDate`, and the widget renders them with
// `Text(timerInterval:)` and `ProgressView(timerInterval:)`, both of which the
// system animates on its own. Updates go out only when the deadline actually
// moves: start, extend, finish, end.

import ActivityKit
import Foundation
import Observation

@MainActor
@Observable
final class RestActivityController {
    static let shared = RestActivityController()

    @ObservationIgnored
    private var activity: Activity<RestActivityAttributes>?

    /// What the last request did, in words a person can read off the phone.
    ///
    /// Every failure below used to go to `print`, which is the Xcode console
    /// and nowhere else. "Live Activity still doesn't work" then had no
    /// evidence behind it: the setting could be off, the request could be
    /// throwing, the extension could be missing from the bundle, or the
    /// activity could be starting and rendering blank — four different
    /// faults with one symptom. Settings shows this string, so the answer
    /// travels with the report.
    private(set) var lastEvent: String = "No rest started yet"
    private(set) var lastEventWasError = false

    private init() {}

    /// False when the user has switched Live Activities off for Vaux, or the
    /// device does not support them. Every entry point checks this rather than
    /// letting `request` throw — a disabled setting is a normal state, not an
    /// error worth logging on every set.
    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Whether the widget extension that draws the activity shipped inside
    /// this build. The app can request an activity without it — the request
    /// succeeds and the Lock Screen shows a blank capsule, or nothing — so
    /// a missing extension is the one fault the request itself never
    /// reports. Looked up by name in the bundle's PlugIns folder.
    var isExtensionInstalled: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        else { return false }
        return items.contains { $0.lastPathComponent == "VauxWidgetsExtension.appex" }
    }

    /// Activities iOS currently holds for this app, running or not.
    var liveCount: Int {
        Activity<RestActivityAttributes>.activities.count
    }

    private func record(_ text: String, error: Bool = false) {
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        lastEvent = "\(text) · \(stamp)"
        lastEventWasError = error
        print("[RestActivity] \(text)")
    }

    /// A 30-second activity started from Settings, so the whole path — the
    /// setting, the request, the extension's rendering — can be checked
    /// without logging a set. Same code as a real rest; only the words differ.
    func startTest() {
        let now = Date()
        start(from: now, to: now.addingTimeInterval(30), exercise: "Test rest",
              sessionType: "Test", nextUp: "Lock the phone — the countdown should be on the Lock Screen")
    }

    /// Begin — or retarget — the rest countdown.
    ///
    /// Reuses the running activity when there is one. A session rests roughly
    /// twenty-eight times; requesting a fresh activity each time would spend
    /// the request budget within the first few exercises and leave the athlete
    /// with a dead island for the rest of the workout.
    func start(from startDate: Date,
               to endDate: Date,
               exercise: String,
               sessionType: String,
               nextUp: String?) {
        guard isAvailable else {
            record("Off in iOS Settings → Vaux → Live Activities", error: true)
            return
        }

        let state = RestActivityAttributes.ContentState(
            startDate: startDate,
            endDate: endDate,
            exercise: exercise,
            nextUp: nextUp,
            isComplete: false
        )

        // Reuse the running activity — but only while it is actually running.
        // Once the athlete swipes it away or iOS ends it, the reference stays
        // non-nil and every later rest updated a dead island: the countdown
        // simply stopped appearing for the rest of the session.
        if let activity {
            switch activity.activityState {
            case .active, .stale:
                Task { await activity.update(content(for: state)) }
                record("Updated the running countdown for \(exercise)")
                return
            default:
                self.activity = nil
            }
        }

        do {
            activity = try Activity.request(
                attributes: RestActivityAttributes(sessionType: sessionType),
                content: content(for: state),
                pushType: nil
            )
            record(isExtensionInstalled
                   ? "Started for \(exercise)"
                   : "Started for \(exercise), but the widget extension is missing from this build",
                   error: !isExtensionInstalled)
        } catch {
            // Most commonly the per-app concurrent-activity limit, or the
            // setting being flipped off between the check above and here.
            // A failed activity must never interrupt a workout, so this is
            // recorded and dropped — the ring and the notification both still
            // work without it.
            record("Request failed: \(error.localizedDescription)", error: true)
            activity = nil
        }
    }

    /// Push the new deadline after `extendRest`. Same activity, one update.
    func extend(from startDate: Date, to endDate: Date, nextUp: String?) {
        guard let activity else { return }
        var state = activity.content.state
        state.startDate = startDate
        state.endDate = endDate
        state.nextUp = nextUp
        state.isComplete = false
        Task { await activity.update(content(for: state)) }
    }

    /// The rest ran out with the app alive. Flip to the finished state and let
    /// it linger briefly — the athlete is walking back to the bar, and an
    /// island that vanishes at the exact moment it becomes relevant is worse
    /// than one that says "Go" for a few seconds.
    func complete() {
        guard let activity else { return }
        var state = activity.content.state
        state.isComplete = true
        let finished = ActivityContent(state: state, staleDate: nil)
        Task {
            await activity.end(finished, dismissalPolicy: .after(.now + 15))
        }
        self.activity = nil
    }

    /// Rest was skipped, or the session ended. Nothing left to say, so take it
    /// off the screen immediately rather than leaving a stale countdown.
    func cancel() {
        guard let activity else { return }
        var state = activity.content.state
        state.isComplete = true
        let finished = ActivityContent(state: state, staleDate: nil)
        Task {
            await activity.end(finished, dismissalPolicy: .immediate)
        }
        self.activity = nil
    }

    /// Clears anything the last run left behind.
    ///
    /// If the app is killed mid-rest, iOS keeps the activity on the Lock
    /// Screen — it has no way to know the workout is over. On the next launch
    /// this ends whatever is still showing, so a session started tomorrow does
    /// not open underneath yesterday's frozen countdown.
    func clearOrphans() {
        for activity in Activity<RestActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil
    }

    /// `staleDate` is the safety net for the suspended case: the app is not
    /// running to call `complete()`, so the widget uses `isStale` to switch
    /// itself to the finished state at the deadline instead of sitting on a
    /// countdown pinned at 0:00.
    private func content(
        for state: RestActivityAttributes.ContentState
    ) -> ActivityContent<RestActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: state.endDate)
    }
}
