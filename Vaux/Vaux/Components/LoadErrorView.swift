// LoadErrorView.swift
// Vaux
//
// Shared presentation for a load that failed.
//
// Two shapes, because a failure means different things depending on what
// survived it:
//
//   LoadErrorState  — nothing cached. Takes over the screen, names the reason,
//                     and offers a retry. The alternative is an empty state,
//                     which would claim the account has no data when really
//                     the fetch never landed.
//   LoadErrorBanner — earlier data is still on screen. Annotates it rather
//                     than replacing it, because stale numbers beat none.
//
// Both name the underlying reason rather than a generic apology: being
// offline, pointing at a wrong backend URL, and holding an expired key are
// different problems with different fixes, and `localizedDescription` already
// tells them apart.

import SwiftUI

struct LoadErrorState: View {
    let message: String
    var title: String = "Couldn't load your data"
    var icon: String = "wifi.exclamationmark"
    /// Drives the button's spinner during the moment between a retry tap and
    /// the owning view switching to its own loading state.
    var isRetrying: Bool = false
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            IconBadge(systemName: icon, accent: .ember, size: 72)

            VStack(spacing: 8) {
                Text(title)
                    .font(.serifMD)
                    .foregroundStyle(Color.fg0)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.uiSmall)
                    .foregroundStyle(Color.fg2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Haptic.light()
                retry()
            } label: {
                CTALabel(text: "Try again", icon: "arrow.clockwise", busy: isRetrying)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(isRetrying)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
    }
}

struct LoadErrorBanner: View {
    let message: String
    var title: String = "Showing your last synced data"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.uiSmall)
                    .foregroundStyle(Color.ember.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.ember)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ember.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.ember.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
