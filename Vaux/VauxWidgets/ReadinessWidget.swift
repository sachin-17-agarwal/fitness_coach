// ReadinessWidget.swift
// VauxWidgets
//
// The Home tab's readiness hero, outside the app: the score in its verdict
// colour, the verdict line naming today's session, the week and phase, the
// block's strength gain, HRV and sleep. Nothing else — no next session, no
// lift list, no charts (roadmap 2.9, settled 17 Sep).
//
// Every number comes from one read of GET /api/widget. Readiness is computed
// on the server with the same formula the Home tab runs (readiness.py mirrors
// Recovery.compositeScore), so the two cannot disagree; the strength number
// is the Strength tab's own, posted by the app when it computes it. The
// widget never computes anything itself.

import SwiftUI
import WidgetKit

// MARK: - Payload

nonisolated struct WidgetStrength: Codable, Hashable, Sendable {
    let medianGainPct: Double?
    let lifts: Int?
}

nonisolated struct WidgetPayload: Codable, Hashable, Sendable {
    let date: String
    /// The date of the readings behind the score; `stale` when it is not
    /// today (a weigh-in wrote today's row before the Health export ran).
    let readDate: String?
    let stale: Bool?
    let score: Int?
    let level: String
    let verdict: String
    let sessionType: String
    let done: Bool
    let week: Int
    let day: Int
    let phase: String
    let hrv: Double?
    let hrvDelta: Int?
    let sleepHours: Double?
    let restingHr: Double?
    let rhrDelta: Int?
    let strength: WidgetStrength?

    static let sample = WidgetPayload(
        date: "2026-09-17", readDate: "2026-09-17", stale: false, score: 82, level: "green", verdict: "READY — PUSH TODAY",
        sessionType: "Push", done: false, week: 4, day: 2, phase: "DELOAD",
        hrv: 68, hrvDelta: 4, sleepHours: 7.33, restingHr: 52, rhrDelta: -1,
        strength: WidgetStrength(medianGainPct: 8.1, lifts: 11))
}

// MARK: - Fetch

nonisolated enum WidgetAPI {
    private static let cacheKey = "widget.lastPayload"

    private static var base: String {
        let raw = Config.backendURL
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        if let range = trimmed.range(of: "/api/chat") { return String(trimmed[..<range.lowerBound]) }
        return trimmed
    }

    static func fetch() async -> WidgetPayload? {
        guard let url = URL(string: "\(base)/api/widget") else { return cached() }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(Config.appAPIToken)", forHTTPHeaderField: "Authorization")
        // WidgetKit gives a provider seconds, not minutes. A slow backend
        // must fall through to the last good read, never hold the timeline.
        req.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return cached() }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let payload = try decoder.decode(WidgetPayload.self, from: data)
            UserDefaults.standard.set(data, forKey: cacheKey)
            return payload
        } catch {
            return cached()
        }
    }

    /// The last good read, so a dead network shows yesterday's number
    /// (marked stale by date) rather than a blank tile.
    static func cached() -> WidgetPayload? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(WidgetPayload.self, from: data)
    }
}

// MARK: - Timeline

nonisolated struct ReadinessEntry: TimelineEntry, Sendable {
    let date: Date
    let payload: WidgetPayload?
}

nonisolated struct ReadinessProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReadinessEntry {
        ReadinessEntry(date: .now, payload: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (ReadinessEntry) -> Void) {
        if context.isPreview {
            completion(ReadinessEntry(date: .now, payload: .sample))
            return
        }
        // A snapshot is wanted now: the last good read at once if there is
        // one, the network only when the cache is empty.
        if let cached = WidgetAPI.cached() {
            completion(ReadinessEntry(date: .now, payload: cached))
            return
        }
        Task { completion(ReadinessEntry(date: .now, payload: await WidgetAPI.fetch())) }
    }

    /// One entry, refreshed on the system's schedule about every 45 minutes:
    /// the morning sync lands before 7, the score does not move after that
    /// until tomorrow, and a finished session flips the verdict — the app
    /// asks for a reload when it logs one.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ReadinessEntry>) -> Void) {
        Task {
            let payload = await WidgetAPI.fetch()
            // Nothing read yet: ask again in five minutes rather than forty-five.
            let minutes = payload == nil ? 5 : 45
            let next = Calendar.current.date(byAdding: .minute, value: minutes, to: .now) ?? .now.addingTimeInterval(2700)
            completion(Timeline(entries: [ReadinessEntry(date: .now, payload: payload)], policy: .after(next)))
        }
    }
}

// MARK: - Palette (Color+Theme.swift is in the app target; kept in step)

private extension Color {
    static let wSignal = Color(red: 0.81, green: 1.00, blue: 0.24)   // #CFFF3E
    static let wSignalInk = Color(red: 0.04, green: 0.06, blue: 0.00)
    static let wAmber = Color(red: 0.96, green: 0.72, blue: 0.31)    // #F5B84E
    static let wEmber = Color(red: 0.95, green: 0.42, blue: 0.29)    // #F26B4A
    static let wFg0 = Color(red: 0.96, green: 0.95, blue: 0.93)      // #F4F3EE
    static let wFg1 = Color(red: 0.81, green: 0.81, blue: 0.78)      // #CFCEC7
    static let wFg2 = Color(red: 0.53, green: 0.53, blue: 0.57)      // #878791
    static let wFg3 = Color(red: 0.40, green: 0.40, blue: 0.45)      // #676773
    static let wHeroTop = Color(red: 0.055, green: 0.165, blue: 0.122) // #0E2A1F
    static let wHeroMid = Color(red: 0.039, green: 0.102, blue: 0.082) // #0A1A15
    static let wBg = Color(red: 0.024, green: 0.031, blue: 0.043)      // #06080B
}

private enum WidgetStyle {
    static func display(_ size: CGFloat) -> Font { .custom("Anton-Regular", size: size) }

    static func verdictColor(_ level: String) -> Color {
        switch level {
        case "green": return .wSignal
        case "yellow": return .wAmber
        case "red": return .wEmber
        default: return .wFg2
        }
    }

    static var hero: LinearGradient {
        LinearGradient(stops: [
            .init(color: .wHeroTop, location: 0),
            .init(color: .wHeroMid, location: 0.55),
            .init(color: .wBg, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    static func signedPct(_ pct: Double) -> String {
        let arrow = pct > 0 ? "▴ " : (pct < 0 ? "▾ " : "")
        return arrow + String(format: "%.1f%%", abs(pct))
    }

    static func clock(_ hours: Double) -> String {
        let total = Int((hours * 60).rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// Today's date, or "READ · THU 17" when the score is yesterday's.
    static func headerDate(_ p: WidgetPayload, long: Bool) -> String {
        if p.stale == true, let read = p.readDate {
            return "READ · " + date(read, long: false)
        }
        return date(p.date, long: long)
    }

    static func date(_ iso: String, long: Bool) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        let date = parser.date(from: iso) ?? Date()
        let out = DateFormatter()
        out.dateFormat = long ? "EEEE · MMM d" : "EEE d"
        return out.string(from: date).uppercased()
    }
}

// MARK: - Rendering mode

/// The system's widget styles. Default draws the hero in full colour. Tinted
/// and Clear (the glass looks the athlete can pick from the widget's style
/// sheet) hand the surface to iOS and want monochrome ink with the accent
/// carried by `widgetAccentable` views — here the score and the verdict.
/// One place decides, so the palette never half-applies.
private struct Ink {
    let mode: WidgetRenderingMode
    var full: Bool { mode == .fullColor }
    var fg1: Color { full ? .wFg1 : .primary.opacity(0.88) }
    var fg2: Color { full ? .wFg2 : .primary.opacity(0.66) }
    var fg3: Color { full ? .wFg3 : .primary.opacity(0.5) }
    func verdict(_ level: String) -> Color { full ? WidgetStyle.verdictColor(level) : .primary }
}

// MARK: - Pieces

private struct VauxMark: View {
    var size: CGFloat = 12
    var color: Color = .wFg1
    var body: some View {
        // The same V as VauxLogo, drawn in a unit box.
        Path { p in
            let w = size, h = size, pad = w * 0.08, arm = w * 0.22
            p.move(to: CGPoint(x: pad, y: pad))
            p.addLine(to: CGPoint(x: w * 0.45, y: h - pad))
            p.addLine(to: CGPoint(x: w * 0.55, y: h - pad))
            p.addLine(to: CGPoint(x: w - pad, y: pad))
            p.addLine(to: CGPoint(x: w - pad - arm, y: pad))
            p.addLine(to: CGPoint(x: w * 0.5, y: h - pad - h * 0.21))
            p.addLine(to: CGPoint(x: pad + arm, y: pad))
            p.closeSubpath()
        }
        .fill(color)
        .frame(width: size, height: size)
    }
}

private struct WidgetHeader: View {
    let dateText: String
    @Environment(\.widgetRenderingMode) private var mode
    var body: some View {
        let ink = Ink(mode: mode)
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                VauxMark(size: 11, color: ink.fg1)
                Text("VAUX")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(2.6)
                    .foregroundStyle(ink.fg1)
            }
            Spacer()
            Text(dateText)
                .font(.system(size: 9, weight: .medium))
                .kerning(2)
                .foregroundStyle(ink.fg3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private struct ScoreFigure: View {
    let payload: WidgetPayload
    let size: CGFloat
    @Environment(\.widgetRenderingMode) private var mode
    var body: some View {
        let color = Ink(mode: mode).verdict(payload.level)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(payload.score.map(String.init) ?? "—")
                .font(WidgetStyle.display(size))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if payload.score != nil {
                Text("%")
                    .font(WidgetStyle.display(size * 0.24))
                    .foregroundStyle(color.opacity(0.55))
            }
        }
        .widgetAccentable()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(payload.score.map { "Readiness \($0) percent" } ?? "Readiness unknown")
    }
}

private struct MetricLine: View {
    let label: String
    let value: String
    var delta: Int? = nil
    @Environment(\.widgetRenderingMode) private var mode
    var body: some View {
        let ink = Ink(mode: mode)
        return (Text(label.isEmpty ? "" : label + " ").foregroundColor(ink.fg2)
         + Text(value).fontWeight(.semibold).foregroundColor(ink.fg1)
         + Text(deltaText).foregroundColor(ink.fg3))
            .font(.system(size: 9.5, weight: .medium))
            .kerning(1.1)
            .monospacedDigit()
            .lineLimit(1)
    }
    private var deltaText: String {
        guard let delta, delta != 0 else { return "" }
        return " " + (delta > 0 ? "▴" : "▾") + "\(abs(delta))"
    }
}

// MARK: - Sizes

private struct MediumView: View {
    let p: WidgetPayload
    @Environment(\.widgetRenderingMode) private var mode
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(dateText: WidgetStyle.headerDate(p, long: true))
            Spacer(minLength: 4)
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    ScoreFigure(payload: p, size: 76)
                    Text(p.verdict)
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(2)
                        .foregroundStyle(Ink(mode: mode).verdict(p.level))
                        .widgetAccentable()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 7) {
                    MetricLine(label: "WEEK \(p.week)", value: p.phase)
                    if let g = p.strength?.medianGainPct {
                        MetricLine(label: "STRENGTH", value: WidgetStyle.signedPct(g))
                    }
                    if let hrv = p.hrv {
                        MetricLine(label: "HRV", value: "\(Int(hrv))", delta: p.hrvDelta)
                    }
                    if let sleep = p.sleepHours {
                        MetricLine(label: "SLEEP", value: WidgetStyle.clock(sleep))
                    }
                }
                .padding(.bottom, 3)
            }
        }
    }
}

private struct SmallView: View {
    let p: WidgetPayload
    @Environment(\.widgetRenderingMode) private var mode
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(dateText: WidgetStyle.headerDate(p, long: false))
            Spacer(minLength: 2)
            ScoreFigure(payload: p, size: 60)
            Text(p.verdict.replacingOccurrences(of: " — ", with: "\n"))
                .font(.system(size: 8.5, weight: .semibold))
                .kerning(1.6)
                .foregroundStyle(Ink(mode: mode).verdict(p.level))
                .widgetAccentable()
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .padding(.top, 5)
            Spacer(minLength: 2)
            HStack {
                MetricLine(label: "WEEK \(p.week)", value: p.phase)
                Spacer()
                if let g = p.strength?.medianGainPct {
                    MetricLine(label: "", value: WidgetStyle.signedPct(g))
                }
            }
        }
    }
}

private struct RectangularView: View {
    let p: WidgetPayload
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(p.score.map(String.init) ?? "—")
                    .font(WidgetStyle.display(34))
                Text("%").font(WidgetStyle.display(11)).opacity(0.6)
            }
            VStack(alignment: .leading, spacing: 3) {
                // Session first: it is the word that changes day to day, and
                // the tile is too narrow for "STEADY · LEGS" at full tracking.
                Text(shortVerdict)
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("WK \(p.week) · \(p.phase)")
                    .font(.system(size: 9.5, weight: .medium))
                    .kerning(0.6)
                    .opacity(0.7)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .widgetAccentable()
    }
    private var shortVerdict: String {
        let head = p.verdict.components(separatedBy: " — ").first ?? p.verdict
        if p.sessionType.isEmpty { return head }
        return p.done ? "\(p.sessionType.uppercased()) · DONE" : "\(p.sessionType.uppercased()) · \(head)"
    }
}

// MARK: - Widget

struct ReadinessWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ReadinessEntry

    var body: some View {
        let p = entry.payload ?? WidgetPayload(
            date: WidgetStyle.isoToday, readDate: nil, stale: false, score: nil, level: "unknown", verdict: "NO READ YET — OPEN VAUX",
            sessionType: "", done: false, week: 0, day: 0, phase: "", hrv: nil, hrvDelta: nil,
            sleepHours: nil, restingHr: nil, rhrDelta: nil, strength: nil)
        Group {
            switch family {
            case .systemSmall: SmallView(p: p)
            case .accessoryRectangular: RectangularView(p: p)
            default: MediumView(p: p)
            }
        }
        .containerBackground(for: .widget) {
            if family == .accessoryRectangular { Color.clear } else { WidgetStyle.hero }
        }
    }
}

private extension WidgetStyle {
    static var isoToday: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

struct ReadinessWidget: Widget {
    let kind = "ReadinessWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ReadinessProvider()) { entry in
            ReadinessWidgetView(entry: entry)
        }
        .configurationDisplayName("Readiness")
        .description("Today's readiness, the session it points at, and the block's strength gain.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
