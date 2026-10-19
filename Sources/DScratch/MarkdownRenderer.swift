import AppKit

/// Turns Claude's Markdown into rich text: headings, bullets, code fences, and inline bold/italic/code/links.
enum MarkdownRenderer {
    static func render(_ markdown: String, baseFont: NSFont = DTextView.defaultFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
        var inFence = false
        for rawLine in markdown.components(separatedBy: "\n") {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                out.append(NSAttributedString(
                    string: rawLine + "\n", attributes: [.font: mono, .foregroundColor: NSColor.textColor]))
                continue
            }
            var line = rawLine
            var font = baseFont
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                line = String(line.dropFirst(hashes + 1))
                font = NSFont.boldSystemFont(ofSize: baseFont.pointSize + CGFloat(max(2, 8 - 2 * hashes)))
            } else {
                let indent = line.prefix { $0 == " " }.count
                let rest = line.dropFirst(indent)
                if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
                    line = String(repeating: "    ", count: indent / 2) + "• " + rest.dropFirst(2)
                }
            }
            out.append(inline(line, font: font, mono: mono))
            out.append(NSAttributedString(string: "\n", attributes: [.font: baseFont, .foregroundColor: NSColor.textColor]))
        }
        while out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    private static func inline(_ text: String, font: NSFont, mono: NSFont) -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        guard let parsed = try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return NSAttributedString(string: text, attributes: plain) }

        let fm = NSFontManager.shared
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var attrs = plain
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { runFont = mono }
                if intent.contains(.stronglyEmphasized) { runFont = fm.convert(runFont, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { runFont = fm.convert(runFont, toHaveTrait: .italicFontMask) }
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            attrs[.font] = runFont
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return out
    }
}
