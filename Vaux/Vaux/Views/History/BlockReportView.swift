// BlockReportView.swift
// Vaux
//
// One page for the block: what was lifted, what moved, what it cost, and the
// two things to fix next block. Rendered to an image for sharing.

import SwiftUI

struct BlockReportView: View {
    let training: TrainingBlockViewModel
    let strength: StrengthViewModel
    let recovery: RecoveryInsightsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var rendered: Image?

    var body: some View {
        NavigationStack {
            ZStack {
                Editorial.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    poster
                        .padding(.bottom, 40)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(Editorial.mid)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let rendered {
                        ShareLink(item: rendered, preview: SharePreview("Block report", image: rendered)) {
                            Image(systemName: "square.and.arrow.up").foregroundStyle(Editorial.lime)
                        }
                    }
                }
            }
            .toolbarBackground(Editorial.bg, for: .navigationBar)
            .task { render() }
        }
    }

    @MainActor
    private func render() {
        let renderer = ImageRenderer(content: poster.frame(width: 390).background(Editorial.bg))
        renderer.scale = 3
        if let ui = renderer.uiImage { rendered = Image(uiImage: ui) }
    }

    private var snap: BlockSnapshot? { strength.latest }

    private var poster: some View {
        let p = training.current
        return VStack(alignment: .leading, spacing: 0) {
            HeroPanel(height: 380) {
                VStack(alignment: .leading, spacing: 0) {
                    HeroTopBar(left: "BLOCK REPORT", right: "\(p.blockLabel) · WEEK \(p.week) OF \(Config.weeksPerBlock)")
                    EditorialEyebrow(text: "LIFTED", color: Editorial.lime, size: 10, kerning: 2.5).padding(.top, 40)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: training.blockTonnage >= 100_000 ? "%.0f" : "%.1f", training.blockTonnage / 1000)).font(.display(150)).foregroundStyle(.white)
                        Text("T").font(.display(56)).foregroundStyle(Editorial.lime)
                    }
                    .frame(height: 130)
                    WaveBarsChart(bars: training.currentWave.map { w in
                        WaveBarsChart.Bar(label: "W\(w.position.week)", phase: w.position.phaseLabel, value: w.tonnage, highlight: w.position.isPeak)
                    })
                    .frame(height: 150)
                    .padding(.horizontal, -Editorial.gutter)
                }
                .padding(.horizontal, Editorial.gutter)
                .padding(.top, 20)
            }
            ledger
            nextBlock
            HStack {
                Text("V").font(.system(size: 15, weight: .semibold, design: .serif))
                Text("VAUX").font(.system(size: 11, weight: .bold)).kerning(4)
                Spacer()
                Text(Date().formatted(.dateTime.day().month(.abbreviated).year()).uppercased()).font(.system(size: 10, weight: .bold)).kerning(1.5)
            }
            .foregroundStyle(Editorial.muted)
            .padding(.horizontal, Editorial.gutter).padding(.top, 24)
        }
        .foregroundStyle(.white)
    }

    private var ledger: some View {
        VStack(spacing: 0) {
            SectionBar(title: "THE BLOCK", right: "")
            row("SESSIONS", "\(training.blockSessions)", "")
            row("WORKING SETS", "\(training.blockSets)", "")
            if let d = training.blockDeltaPct { row("VS LAST BLOCK", Editorial.signedPct(d, decimals: 0), "TONNAGE, SAME WEEKS") }
            if let s = snap, s.judgedCount > 0 {
                row("MEDIAN STRENGTH GAIN", s.medianGainPct.map { Editorial.signedPct($0) } ?? "—", "PEAK WEEK VS PEAK WEEK")
                row("ALL-TIME PRS", "\(s.prCount)", s.lifts.filter { $0.state == .pr }.map(\.name).joined(separator: " · ").uppercased())
            } else {
                row("STRENGTH", "—", "NEEDS TWO BLOCKS OF STAMPED SESSIONS")
            }
            if let drop = recovery.peakWeekHRVDrop { row("HRV COST OF PEAK WEEK", "\(drop > 0 ? "−" : "+")\(Int(abs(drop).rounded())) MS", "MEAN VS YOUR RANGE") }
            if recovery.shortNights > 0 { row("SHORT NIGHTS", "\(recovery.shortNights)", "UNDER 7H · \(recovery.shortNightsInPeakWeek) IN PEAK WEEK") }
        }
    }

    private func row(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Editorial.rule).frame(height: 1)
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    EditorialEyebrow(text: label, size: 10, kerning: 2.5)
                    if !note.isEmpty { Text(note).font(.system(size: 10, weight: .semibold)).kerning(1).foregroundStyle(Editorial.muted).lineLimit(2) }
                }
                Spacer()
                Text(value).font(.display(40)).foregroundStyle(.white)
            }
            .padding(.horizontal, Editorial.gutter).padding(.vertical, 14)
        }
    }

    private var nextBlock: some View {
        let stalls = snap?.lifts.filter { $0.state == .stall || $0.state == .drop }.sorted { $0.state.attention < $1.state.attention } ?? []
        let shorts = snap?.muscles.filter { $0.state == .short } ?? []
        return VStack(alignment: .leading, spacing: 0) {
            SectionBar(title: "NEXT BLOCK", right: "TWO THINGS")
            if stalls.isEmpty && shorts.isEmpty {
                NoReadNote(text: snap?.judgedCount ?? 0 > 0 ? "Nothing stalled and nothing short. Run the programme again." : "The first block-over-block reading arrives at the end of the next peak week.")
            }
            if let s = stalls.first {
                item("1", "\(s.name.uppercased()) · \(s.state.label)", "Reset the working load 5% and rebuild the reps, or change the variation. \(Editorial.signedPct(s.deltaPct ?? 0)) over the block.")
            }
            if let m = shorts.first {
                item(stalls.isEmpty ? "1" : "2", "\(m.muscle.rawValue.uppercased()) · SHORT ON SETS", "\(String(format: "%.1f", m.setsPerWeek)) sets a week against a \(m.band.lowerBound)–\(m.band.upperBound) band. Put the difference in the weak-point block.")
            } else if stalls.count > 1 {
                let s = stalls[1]
                item("2", "\(s.name.uppercased()) · \(s.state.label)", "\(Editorial.signedPct(s.deltaPct ?? 0)) over the block. Watch it through week 2 before changing anything.")
            }
        }
    }

    private func item(_ n: String, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Editorial.rule).frame(height: 1)
            HStack(alignment: .top, spacing: 16) {
                Text(n).font(.display(40)).foregroundStyle(Editorial.lime)
                VStack(alignment: .leading, spacing: 6) {
                    EditorialEyebrow(text: title, color: .white, size: 11, kerning: 2)
                    Text(body).font(.system(size: 13)).lineSpacing(3).foregroundStyle(Editorial.mid)
                }
            }
            .padding(.horizontal, Editorial.gutter).padding(.vertical, 16)
        }
    }
}
