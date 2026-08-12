// VauxWidgetsBundle.swift
// VauxWidgets
//
// Entry point for the widget extension. Only the rest Live Activity lives
// here for now; home-screen widgets would be added to the same bundle.

import SwiftUI
import WidgetKit

@main
struct VauxWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RestLiveActivity()
    }
}
