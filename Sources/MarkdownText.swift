import SwiftUI

/// Renders a small, practical subset of Markdown: `#`/`##`/`###` headings,
/// `-`/`*` bullets, `1.` numbered items, blank-line paragraph breaks, and
/// inline **bold**, *italic*, `code` and [links](https://…) on every line.
/// SwiftUI's own Markdown support only does the inline part.
struct MarkdownText: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(Int, String), bullet(String), numbered(String, String), paragraph(String), gap
    }

    private var blocks: [Block] {
        var out: [Block] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if out.last != .gap && !out.isEmpty { out.append(.gap) }
            } else if let h = Self.heading(line) {
                out.append(.heading(h.0, h.1))
            } else if let first = line.first, "-*•".contains(first), line.dropFirst().first == " " {
                out.append(.bullet(String(line.dropFirst(2))))
            } else if let n = Self.numbered(line) {
                out.append(.numbered(n.0, n.1))
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }

    /// "## Title" -> (2, "Title"); up to three #.
    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    /// "12. Text" or "12) Text" -> ("12", "Text").
    private static func numbered(_ line: String) -> (String, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return (String(digits), String(rest.dropFirst(2)))
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
        return Text(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let s):
                    inline(s).font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                        .padding(.top, 4)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); inline(s) }
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("\(n).").monospacedDigit(); inline(s) }
                case .paragraph(let s):
                    inline(s)
                case .gap:
                    Spacer().frame(height: 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
