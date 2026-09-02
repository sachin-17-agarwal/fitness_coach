// BodyMapView.swift
// Vaux
//
// Front and back muscle maps coloured by `StrengthState`. The figure is a
// stylised athlete drawn from a handful of mirrored paths (the right half is
// authored; the left is its reflection), so it scales to any size crisply.
// Tapping a muscle reports its name; the Strength tab filters on it.

import SwiftUI

enum BodyView { case front, back }

/// Muscle names as the body map knows them. `ExerciseCatalog` groups map
/// onto these in `StrengthViewModel`.
enum BodyMuscle: String, CaseIterable, Hashable {
    case chest = "Chest", shoulders = "Shoulders", biceps = "Biceps", abs = "Abs", quads = "Quads", calves = "Calves"
    case back = "Back", rearDelts = "Rear Delts", triceps = "Triceps", glutes = "Glutes", hamstrings = "Hamstrings"
}

/// A tiny SVG path reader: absolute M / L / Q / Z only, which is all the
/// figure uses. Coordinates are in a 160 × 364 box.
struct SVGPath: Shape {
    let d: String
    var mirrored = false

    static let boxW: CGFloat = 160, boxH: CGFloat = 364

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / Self.boxW, sy = rect.height / Self.boxH
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let mx = mirrored ? Self.boxW - x : x
            return CGPoint(x: rect.minX + mx * sx, y: rect.minY + y * sy)
        }
        var p = Path()
        let scanner = Scanner(string: d)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n")
        var cmd: Character = "M"
        func number() -> CGFloat? { scanner.scanDouble().map { CGFloat($0) } }
        while !scanner.isAtEnd {
            if let c = scanner.scanCharacter(), "MLQZ".contains(c) { cmd = c }
            else { scanner.currentIndex = scanner.string.index(before: scanner.currentIndex) }
            switch cmd {
            case "M": if let x = number(), let y = number() { p.move(to: pt(x, y)) } else { return p }
            case "L": if let x = number(), let y = number() { p.addLine(to: pt(x, y)) } else { return p }
            case "Q": if let cx = number(), let cy = number(), let x = number(), let y = number() { p.addQuadCurve(to: pt(x, y), control: pt(cx, cy)) } else { return p }
            case "Z": p.closeSubpath(); if scanner.isAtEnd { return p }
            default: return p
            }
        }
        return p
    }
}

enum BodyPaths {
    static let head = "M80,7 Q94,7 94,24 Q94,41 80,41 Q66,41 66,24 Q66,7 80,7 Z"
    static let neck = "M72,38 L88,38 L91,52 L69,52 Z"
    /// Right half of the silhouette; mirrored for the left.
    static let half = "M80,50 Q98,50 112,58 Q128,62 132,78 Q138,100 136,126 Q138,156 142,180 Q144,200 140,216 Q142,232 130,234 Q122,232 122,214 Q120,190 118,160 Q116,132 110,104 Q104,120 102,146 Q100,170 106,190 Q112,212 108,244 Q106,272 104,296 Q108,320 104,342 Q104,356 98,360 Q88,362 86,352 Q90,320 88,300 Q84,270 84,236 Q84,214 80,206 Z"
    static let forearm = "M118,150 Q134,152 138,178 Q140,204 130,212 Q122,206 120,180 Z"
    static let knee = "M89,296 Q99,294 100,302 Q99,310 94,310 Q88,308 89,296 Z"
    static let pelvis = "M84,190 Q104,190 108,206 Q104,220 84,222 Z"

    static let front: [(BodyMuscle, [String])] = [
        (.chest, ["M84,64 Q104,60 114,74 Q118,92 104,104 Q88,110 84,104 Z"]),
        (.shoulders, ["M108,58 Q126,60 130,78 Q126,92 114,90 Q106,80 108,58 Z"]),
        (.biceps, ["M112,96 Q128,100 130,124 Q128,142 118,146 Q112,130 112,96 Z"]),
        (.abs, ["M81,112 L93,112 L93,128 L81,128 Z", "M81,131 L93,131 L93,147 L81,147 Z", "M81,150 L93,150 L93,166 L81,166 Z", "M81,169 L93,169 L91,186 L81,186 Z", "M96,110 Q106,136 100,178 Q94,178 95,112 Z"]),
        (.quads, ["M92,212 Q102,216 100,262 Q98,284 92,286 Q88,262 88,222 Z", "M100,222 Q110,236 108,270 Q106,290 100,292 Q102,260 100,222 Z", "M86,252 Q92,266 90,290 Q86,292 84,272 Z"]),
        (.calves, ["M96,308 Q104,320 102,346 Q98,352 94,344 Q92,320 96,308 Z"]),
    ]
    static let back: [(BodyMuscle, [String])] = [
        (.back, ["M80,52 L108,62 Q102,80 90,108 L80,110 Z", "M108,86 Q112,104 104,132 Q96,158 84,166 L84,116 Q90,100 108,86 Z", "M82,116 L90,116 Q92,150 90,182 L82,182 Z"]),
        (.rearDelts, ["M108,58 Q126,60 130,78 Q126,92 114,90 Q106,80 108,58 Z"]),
        (.triceps, ["M112,96 Q128,100 130,124 Q128,142 118,146 Q112,130 112,96 Z"]),
        (.glutes, ["M82,186 Q108,184 108,208 Q104,226 84,226 Z"]),
        (.hamstrings, ["M88,230 Q98,232 98,272 Q97,290 90,292 Q86,270 88,230 Z", "M100,230 Q108,236 106,272 Q104,290 100,292 Q100,262 100,230 Z"]),
        (.calves, ["M88,302 Q98,306 96,340 Q92,348 88,344 Q84,320 88,302 Z", "M98,302 Q106,306 104,340 Q100,348 98,344 Q98,320 98,302 Z"]),
    ]
}

struct BodyFigure: View {
    let view: BodyView
    let states: [BodyMuscle: StrengthState]
    var selected: BodyMuscle? = nil
    var onTap: ((BodyMuscle) -> Void)? = nil

    private static let base = Color(hex: "0D1712")
    private static let edge = Color.white.opacity(0.10)

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            ZStack {
                // Silhouette
                SVGPath(d: BodyPaths.head).fill(Self.base).overlay(SVGPath(d: BodyPaths.head).stroke(Self.edge, lineWidth: 1))
                SVGPath(d: BodyPaths.neck).fill(Self.base)
                ForEach([false, true], id: \.self) { m in
                    SVGPath(d: BodyPaths.half, mirrored: m).fill(Self.base)
                        .overlay(SVGPath(d: BodyPaths.half, mirrored: m).stroke(Self.edge, lineWidth: 1))
                    SVGPath(d: BodyPaths.forearm, mirrored: m).fill(Color.white.opacity(0.035))
                    SVGPath(d: BodyPaths.knee, mirrored: m).fill(Color.black.opacity(0.35))
                    if view == .front { SVGPath(d: BodyPaths.pelvis, mirrored: m).fill(Color.white.opacity(0.03)) }
                }
                // Muscles
                let groups = view == .front ? BodyPaths.front : BodyPaths.back
                ForEach(groups.indices, id: \.self) { gi in
                    let (muscle, paths) = groups[gi]
                    let state: StrengthState = states[muscle] ?? StrengthState.none
                    let dim = selected != nil && selected != muscle
                    ForEach(paths.indices, id: \.self) { pi in
                        ForEach([false, true], id: \.self) { m in
                            let shape = SVGPath(d: paths[pi], mirrored: m)
                            shape.fill(state.color)
                                .overlay(shape.stroke(Editorial.bg, lineWidth: 1.5))
                                .shadow(color: state == StrengthState.none ? .clear : state.color.opacity(dim ? 0 : 0.55), radius: 4)
                                .opacity(dim ? 0.35 : 1)
                                .overlay(
                                    selected == muscle ? shape.stroke(.white, lineWidth: 1.5) : nil
                                )
                                .contentShape(shape)
                                .onTapGesture { onTap?(muscle) }
                                .accessibilityLabel("\(muscle.rawValue), \(state.label.lowercased())")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                }
            }
            .frame(width: rect.width, height: rect.height)
            .animation(Motion.smooth, value: states)
        }
        .aspectRatio(SVGPath.boxW / SVGPath.boxH, contentMode: .fit)
    }
}

/// Front + back side by side with FRONT / BACK captions.
struct BodyMapView: View {
    let states: [BodyMuscle: StrengthState]
    @Binding var selected: BodyMuscle?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach([BodyView.front, .back], id: \.self) { v in
                VStack(spacing: 8) {
                    BodyFigure(view: v, states: states, selected: selected) { m in
                        Haptic.selection()
                        withAnimation(Motion.snappy) { selected = (selected == m) ? nil : m }
                    }
                    Text(v == .front ? "FRONT" : "BACK")
                        .font(.system(size: 10, weight: .bold)).kerning(2)
                        .foregroundStyle(Editorial.muted)
                }
            }
        }
    }
}
