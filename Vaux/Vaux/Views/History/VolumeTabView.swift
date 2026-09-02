// VolumeTabView.swift
// Vaux
//
// Working sets this week as the hero, tonnage by day inside it, then every
// muscle against its weekly band — short first, then over, then in band —
// with the shortfall written in sets.

import SwiftUI

struct VolumeTabView: View {
    let vm: WeeklyVolumeViewModel
    let calendar: BlockCalendar
    @Binding var tab: HistoryView.Tab
    let askCoach: (String) -> Void

    private struct Row: Identifiable {
        let group: String; let sets: Double; let band: ClosedRange<Int>
        var id: String { group }
        var short: Double { max(0, Double(band.lowerBound) - sets) }
        var over: Double { max(0, sets - Double(band.upperBound)) }
        var order: Int { short > 0 ? 0 : (over > 0 ? 1 : 2) }
    }

    private var rows: [Row] {
        vm.setsByMuscleGroup.map { Row(group: $0.group, sets: $0.setsPerWeek, band: VolumeBands.targetRange(for: $0.group)) }
            .sorted { a, b in
                if a.order != b.order { return a.order < b.order }
                if a.order == 0 { return a.short > b.short }
                if a.order == 1 { return a.over > b.over }
                return a.sets > b.sets
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            DiagnosisText(text: diagnosis, coachPrompt: coachPrompt, askCoach: askCoach)
            SectionBar(title: "SETS PER MUSCLE", right: "14-DAY AVG · BAND = TARGET")
            if rows.isEmpty {
                NoReadNote(text: "No working sets in the last 14 days.")
            }
            ForEach(rows) { r in
                let out = r.order != 2
                let col: Color = out ? Editorial.amber : Editorial.emerald
                let eyebrow = r.short > 0 ? "▾ \(Self.g(r.short)) SHORT" : (r.over > 0 ? "▴ \(Self.g(r.over)) OVER" : "IN BAND")
                PosterRow(eyebrow: eyebrow, eyebrowColor: out ? Editorial.amber : Editorial.muted, title: r.group,
                          value: Self.g(r.sets), unit: "/ \(r.band.lowerBound)–\(r.band.upperBound)") {
                    BandBar(value: r.sets, band: r.band, color: col)
                        .padding(.horizontal, Editorial.gutter).padding(.top, 14).padding(.bottom, 18)
                }
            }
            if !vm.uncategorizedExercises.isEmpty {
                NoReadNote(text: "Not counted toward any muscle: " + vm.uncategorizedExercises.map { "\($0.name) (\($0.setCount))" }.joined(separator: ", ") + ". Add them to the exercise library to include them.")
            }
        }
    }

    private static func g(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    private var outOfBand: Int { rows.filter { $0.order != 2 }.count }
    private var activeDays: Int { vm.tonnageByDay.filter { $0.tonnage > 0 }.count }

    private var hero: some View {
        HeroPanel(height: 540) {
            VStack(alignment: .leading, spacing: 0) {
                HeroTopBar(left: "VOLUME", right: "THIS WEEK · LAST 7 DAYS")
                HistoryTabChips(selected: $tab).padding(.top, 14)
                EditorialEyebrow(text: "WORKING SETS", color: Editorial.lime, size: 10, kerning: 2.5).padding(.top, 18)
                HStack(alignment: .bottom) {
                    CountUpFigure(value: Double(vm.thisWeekSets), size: 132)
                    Spacer()
                    StatStack(lines: [
                        .init(text: "\(Editorial.tonnage(vm.thisWeekTonnage)) LIFTED"),
                        .init(text: "\(activeDays) OF 7 DAYS"),
                        .init(text: "\(outOfBand) OF \(rows.count) OUT OF BAND", color: outOfBand > 0 ? Editorial.amber : Editorial.mid),
                    ]).padding(.bottom, 10)
                }
                .frame(height: 124)
                EditorialEyebrow(text: "TONNAGE BY DAY", color: Editorial.muted, size: 9.5, kerning: 2).padding(.top, 10)
                DayBarsChart(days: vm.tonnageByDay.map { d in
                    DayBarsChart.Day(label: d.date.formatted(.dateTime.weekday(.narrow)).uppercased(),
                                     value: d.tonnage / 1000, highlight: Calendar.current.isDateInToday(d.date))
                })
                .frame(height: 190)
                .padding(.horizontal, -Editorial.gutter)
            }
            .padding(.horizontal, Editorial.gutter)
            .padding(.top, 58)
        }
    }

    private var diagnosis: AttributedString {
        guard !rows.isEmpty else { return .editorial([("Volume needs working sets in the last two weeks.", false)]) }
        let shorts = rows.filter { $0.short > 0 }.map { $0.group.lowercased() }
        let overs = rows.filter { $0.over > 0 }.map { $0.group.lowercased() }
        var parts: [(String, Bool)] = []
        if shorts.isEmpty && overs.isEmpty { parts.append(("Every muscle sits inside its band this fortnight.", false)) }
        if !shorts.isEmpty { parts.append((Self.list(shorts).capitalized, true)); parts.append((shorts.count == 1 ? " is short of its band. " : " are short of their bands. ", false)) }
        if !overs.isEmpty { parts.append((Self.list(overs).capitalized, false)); parts.append((overs.count == 1 ? " runs over. " : " run over. ", false)) }
        if !shorts.isEmpty { parts.append(("The weak-point block on the next Cardio + Abs day is where the short sets go.", false)) }
        return .editorial(parts)
    }

    private var coachPrompt: String? {
        guard !rows.isEmpty else { return nil }
        var lines = ["Looking at my Volume tab (weekly sets, 14-day average):"]
        for r in rows where r.order != 2 { lines.append("- \(r.group): \(Self.g(r.sets)) sets/wk against \(r.band.lowerBound)–\(r.band.upperBound)") }
        lines.append("How should the weak-point block be set this week?")
        return lines.joined(separator: "\n")
    }

    private static func list(_ xs: [String]) -> String {
        if xs.count <= 1 { return xs.first ?? "" }
        return xs.dropLast().joined(separator: ", ") + " and " + xs.last!
    }
}
