// VauxWidgetsEntryPoint.swift
// VauxWidgets
//
// The extension's @main. Every widget extension needs exactly one, and there
// must be exactly one across the whole target.
//
// Xcode's Widget Extension template generates this as `VauxWidgetsBundle.swift`.
// This file deliberately does NOT use that name: shipping a file the template
// also creates meant the wizard and the repo fought over it, and deleting "the
// template files" took the entry point with them. A distinct filename makes
// that impossible to repeat — if the target is ever recreated, the generated
// bundle file can simply be deleted without touching this one.
//
// If a `VauxWidgetsBundle.swift` does appear alongside this file, delete that
// one. Two @main declarations will not compile.

import SwiftUI
import WidgetKit

@main
struct VauxWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RestLiveActivity()
    }
}
