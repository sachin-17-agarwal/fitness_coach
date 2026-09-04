// PullToRefresh.swift
// Vaux
//
// Pull to refresh in the app's own language, replacing the system spinner.
// As you pull, a hairline draws out from the centre and the V mark scales in;
// past the threshold the label turns to RELEASE and the phone taps once. While
// the refresh runs, a lime segment sweeps the hairline under SYNCING; when it
// lands, UPDATED holds for a moment and the strip folds away.
//
// Built on the scroll geometry and phase callbacks rather than `.refreshable`,
// so nothing from UIKit draws underneath it.

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let threshold: CGFloat = 76
    private let stripHeight: CGFloat = 56

    private var showingStrip: Bool { refreshing || finished }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: showingStrip ? stripHeight : 0)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                -(geo.contentOffset.y + geo.contentInsets.top)
            } action: { _, overscroll in
                guard !showingStrip else { return }
                pull = max(0, overscroll)
                let nowArmed = pull >= threshold
                if nowArmed != armed {
                    armed = nowArmed
                    if nowArmed { Haptic.medium() }
                }
            }
            .onScrollPhaseChange { old, new in
                // Releasing while armed fires the refresh. Anything else
                // (letting go early, momentum) just lets the strip retract.
                if old == .interacting, new != .interacting, armed, !refreshing {
                    start()
                }
            }
            .overlay(alignment: .top) { indicator }
            .animation(Motion.smooth, value: showingStrip)
    }

    private func start() {
        armed = false
        refreshing = true
        Task {
            await action()
            Haptic.light()
            refreshing = false
            finished = true
            try? await Task.sleep(for: .milliseconds(650))
            finished = false
        }
    }

    // MARK: - Indicator

    private var progress: CGFloat { min(1, pull / threshold) }

    private var label: String {
        if refreshing { return "Syncing" }
        if finished { return "Updated" }
        return armed ? "Release to sync" : "Pull to sync"
    }

    @ViewBuilder
    private var indicator: some View {
        let height = showingStrip ? stripHeight : min(pull, stripHeight + 16)
        if height > 2 {
            VStack(spacing: 10) {
                Spacer(minLength: 0)
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
            .frame(height: height)
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
