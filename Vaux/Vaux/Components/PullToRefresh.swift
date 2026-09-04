// PullToRefresh.swift
// Vaux
//
// Pull to refresh in the app's own language, replacing the system spinner.
// As you pull, a hairline draws out from the centre and the V mark rises in;
// past the threshold the label turns to RELEASE and the phone taps once. While
// the refresh runs, a lime segment sweeps the hairline under SYNCING; when it
// lands, UPDATED holds for a moment and the strip folds away.
//
// Built on the scroll geometry and phase callbacks rather than `.refreshable`,
// so nothing from UIKit draws underneath it. The strip is made with padding
// on the scroll view, not a content inset: changing a scroll view's insets
// mid-bounce moves its offset in one frame, which is the jump this used to
// have. Padding animates as layout, and the bounce runs on its own inside.

import SwiftUI

extension View {
    /// Drop-in for `.refreshable`: attach to a ScrollView.
    func vauxRefreshable(_ action: @escaping () async -> Void) -> some View {
        modifier(VauxRefreshable(action: action))
    }
}

private struct VauxRefreshable: ViewModifier {
    let action: () async -> Void

    @State private var pull: CGFloat = 0
    @State private var armed = false
    @State private var refreshing = false
    @State private var finished = false
    /// How far the scroll view's top sits above this modifier's frame — the
    /// status-bar height when the scroll view ignores the top safe area
    /// (History), otherwise zero. The gap the user opens starts at the scroll
    /// view's top, but the indicator is laid out from ours, so the visible
    /// part of the gap is `pull - bleed`.
    @State private var bleed: CGFloat = 0
    @State private var scrollTop: CGFloat = 0
    @State private var frameTop: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let stripHeight: CGFloat = 56
    private var threshold: CGFloat { 88 + bleed }
    private var showingStrip: Bool { refreshing || finished }
    /// The part of the opened gap below the status bar.
    private var visiblePull: CGFloat { max(0, pull - bleed) }

    func body(content: Content) -> some View {
        content
            .background { TopEdgeReader(y: $scrollTop) }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                -(geo.contentOffset.y + geo.contentInsets.top)
            } action: { _, overscroll in
                pull = max(0, overscroll)
                guard !showingStrip else {
                    if armed { armed = false }
                    return
                }
                let nowArmed = pull >= threshold
                if nowArmed != armed {
                    armed = nowArmed
                    if nowArmed { Haptic.medium() }
                }
            }
            .onScrollPhaseChange { old, new in
                // Releasing while armed fires the refresh. Anything else
                // (letting go early, momentum) just lets the gap close.
                if old == .interacting, new != .interacting, armed, !showingStrip {
                    start()
                }
            }
            .padding(.top, showingStrip ? stripHeight : 0)
            .background { TopEdgeReader(y: $frameTop) }
            .overlay(alignment: .top) { indicator }
            .onChange(of: scrollTop) { _, _ in measureBleed() }
            .onChange(of: frameTop) { _, _ in measureBleed() }
    }

    private func measureBleed() {
        // Only while the strip is down: with it up, the padding moves the
        // scroll view and the difference no longer means anything.
        guard !showingStrip else { return }
        bleed = max(0, frameTop - scrollTop)
    }

    private func start() {
        armed = false
        withAnimation(Motion.smooth) { refreshing = true }
        Task {
            await action()
            Haptic.light()
            withAnimation(Motion.smooth) {
                refreshing = false
                finished = true
            }
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(Motion.smooth) { finished = false }
        }
    }

    // MARK: - Indicator

    private var progress: CGFloat { min(1, visiblePull / max(1, threshold - bleed)) }

    private var label: String {
        if refreshing { return "Syncing" }
        if finished { return "Updated" }
        return armed ? "Release to sync" : "Pull to sync"
    }

    @ViewBuilder
    private var indicator: some View {
        let height = showingStrip ? stripHeight : min(visiblePull, stripHeight + 16)
        if height > 2 {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    VauxLogo(size: 16, color: finished ? .mint : .signal)
                        .scaleEffect(showingStrip ? 1 : 0.6 + 0.4 * progress)
                        .opacity(showingStrip ? 1 : Double(progress))
                        .modifier(Pulse(active: refreshing && !reduceMotion))
                    EditorialEyebrow(text: label, color: finished ? .mint : (armed || showingStrip ? .signal : Editorial.muted), size: 9.5, kerning: 2.5)
                        .opacity(showingStrip ? 1 : Double(min(1, progress * 1.4)))
                }
                hairline
                    .padding(.horizontal, Editorial.gutter)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)
            // Anchored to the bottom edge, so it rises out from under the
            // content as the gap opens instead of centring in it.
            .frame(height: height, alignment: .bottom)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
    }

    /// Draws out from the centre with the pull; sweeps while syncing.
    private var hairline: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.line)
                    .frame(width: showingStrip ? w : w * progress)
                    .frame(width: w, alignment: .center)
                if refreshing {
                    Sweep(width: w, active: !reduceMotion)
                } else if finished {
                    Rectangle().fill(Color.mint).frame(width: w)
                }
            }
        }
        .frame(height: 1)
    }
}

/// Reports where a view's top edge sits on screen.
private struct TopEdgeReader: View {
    @Binding var y: CGFloat

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.frame(in: .global).minY, initial: true) { _, top in
                    y = top
                }
        }
    }
}

/// A lime segment that runs the width of the line and repeats.
private struct Sweep: View {
    let width: CGFloat
    let active: Bool
    @State private var x: CGFloat = -0.3

    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [Color.signal.opacity(0), Color.signal, Color.signal.opacity(0)], startPoint: .leading, endPoint: .trailing))
            .frame(width: width * 0.3)
            .offset(x: x * width)
            .onAppear {
                guard active else { x = 0.35; return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { x = 1.0 }
            }
    }
}

/// A slow breathe on the mark while the refresh runs.
private struct Pulse: ViewModifier {
    let active: Bool
    @State private var up = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? (up ? 1.12 : 0.92) : 1)
            .onChange(of: active, initial: true) { _, on in
                if on {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { up = true }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { up = false }
                }
            }
    }
}
