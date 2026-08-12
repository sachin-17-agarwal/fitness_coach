// RestLiveActivity.swift
// VauxWidgets
//
// Lock Screen and Dynamic Island presentation for the rest countdown.
//
// Every countdown here is `Text(timerInterval:)` and every bar is
// `ProgressView(timerInterval:)`. Neither needs an update to advance — the
// system animates between the two dates in the state. That is what keeps the
// island ticking while Vaux is suspended, and it is why the app pushes an
// update only when the deadline genuinely moves.
//
// Sizing note: the compact and minimal regions are hard-constrained by iOS,
// and a timer whose glyph widths change ("9:59" -> "10:00") makes the island
// visibly jump. `monospacedDigit()` plus a fixed frame holds the layout still.

import ActivityKit
import SwiftUI
import WidgetKit

// The app's palette lives in the app target; the widget is a separate binary,
// so the three values it needs are restated here rather than sharing a file
// for the sake of three colours. Kept in step with Color+Theme.swift.
private extension Color {
    static let vauxSignal = Color(red: 0.81, green: 1.00, blue: 0.24)  // #CFFF3E
    static let vauxMint   = Color(red: 0.49, green: 0.91, blue: 0.71)  // #7CE8B5
    static let vauxFg2    = Color(red: 0.53, green: 0.53, blue: 0.57)  // #878791
}

struct RestLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestActivityAttributes.self) { context in
            LockScreenRestView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.vauxSignal)
        } dynamicIsland: { context in
            let done = context.isStale || context.state.isComplete

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.sessionType.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Color.vauxFg2)
                        Text(context.state.exercise)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if done {
                        Text("Go")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.vauxMint)
                    } else {
                        Text(timerInterval: context.state.startDate...context.state.endDate,
                             countsDown: true)
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(Color.vauxSignal)
                            .frame(width: 78)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !done {
                            ProgressView(
                                timerInterval: context.state.startDate...context.state.endDate,
                                countsDown: true
                            )
                            .progressViewStyle(.linear)
                            .tint(.vauxSignal)
                            .labelsHidden()
                        }
                        if let next = context.state.nextUp, !next.isEmpty {
                            Text(next)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.vauxFg2)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: done ? "figure.strengthtraining.traditional" : "timer")
                    .foregroundStyle(done ? Color.vauxMint : Color.vauxSignal)
            } compactTrailing: {
                if done {
                    Text("Go")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.vauxMint)
                } else {
                    Text(timerInterval: context.state.startDate...context.state.endDate,
                         countsDown: true)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.vauxSignal)
                        .frame(width: 44)
                }
            } minimal: {
                Image(systemName: done ? "checkmark" : "timer")
                    .foregroundStyle(done ? Color.vauxMint : Color.vauxSignal)
            }
            .keylineTint(.vauxSignal)
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenRestView: View {
    let context: ActivityViewContext<RestActivityAttributes>

    private var done: Bool { context.isStale || context.state.isComplete }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(done ? "REST COMPLETE" : "RESTING")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(done ? Color.vauxMint : Color.vauxFg2)

                Text(context.state.exercise)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let next = context.state.nextUp, !next.isEmpty {
                    Text(next)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vauxFg2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !done {
                    ProgressView(
                        timerInterval: context.state.startDate...context.state.endDate,
                        countsDown: true
                    )
                    .progressViewStyle(.linear)
                    .tint(.vauxSignal)
                    .labelsHidden()
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            if done {
                Text("Go")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.vauxMint)
            } else {
                Text(timerInterval: context.state.startDate...context.state.endDate,
                     countsDown: true)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Color.vauxSignal)
                    .frame(width: 104)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
