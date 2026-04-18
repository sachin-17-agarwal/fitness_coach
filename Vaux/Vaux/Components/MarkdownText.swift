// MarkdownText.swift
// Vaux
//
// Renders a subset of markdown (bold, italic, bullets, inline code) as a
// styled SwiftUI Text view. Used by the coach chat and briefing views so
// Claude's formatting comes through cleanly.

import SwiftUI

struct MarkdownText: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block parsing

    private enum Block: Hashable {
        case paragraph(String)
        case bullet([String])
        case numbered([String])
    }

    private var blocks: [Block] {
        let lines = content.components(separatedBy: "\n")
        var result: [Block] = []
        var buffer: [String] = []
        var bulletBuffer: [String] = []
        var numberedBuffer: [String] = []

        func flushParagraph() {
            if !buffer.isEmpty {
                let text = buffer.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    result.append(.paragraph(text))
                }
                buffer.removeAll()
            }
        }
        func flushBullets() {
            if !bulletBuffer.isEmpty {
                result.append(.bullet(bulletBuffer))
                bulletBuffer.removeAll()
            }
        }
        func flushNumbered() {
            if !numberedBuffer.isEmpty {
                result.append(.numbered(numberedBuffer))
                numberedBuffer.removeAll()
            }
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                flushBullets()
                flushNumbered()
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph()
                flushNumbered()
                bulletBuffer.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                flushParagraph()
                flushBullets()
                let rest = String(line[match.upperBound...])
                numberedBuffer.append(rest)
            } else {
                flushBullets()
                flushNumbered()
                buffer.append(line)
            }
        }
        flushParagraph()
        flushBullets()
        flushNumbered()
        return result
    }

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(inlineAttributed(text))
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundStyle(Color.recoveryGreen)
                        Text(inlineAttributed(item))
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).")
                            .foregroundStyle(Color.recoveryGreen)
                            .fontWeight(.semibold)
                        Text(inlineAttributed(item))
                    }
                }
            }
        }
    }

    // MARK: - Inline formatting

    /// Converts `**bold**` and `*italic*` markers into AttributedString.
    /// Falls back to SwiftUI's built-in markdown parser for safety.
    private func inlineAttributed(_ text: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return parsed
        }
        return AttributedString(text)
    }
}

#Preview {
    MarkdownText(content: """
    Recovery is looking **strong** today — HRV is trending up.

    Key focus:
    - Full ROM on every rep
    - Keep RPE under 8.5
    - 2 min rest between working sets

    You're on track. Go hit it.
    """)
    .padding()
    .background(Color.background)
    .foregroundStyle(.white)
}
