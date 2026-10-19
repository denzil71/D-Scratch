import AppKit

struct CodeTheme: Identifiable {
    let id: String
    let name: String
    let background: NSColor
    let border: NSColor
    let plain: NSColor
    let keyword: NSColor
    let string: NSColor
    let comment: NSColor
    let number: NSColor
    let type: NSColor
    let function: NSColor

    static let changedNotification = Notification.Name("DScratchCodeThemeChanged")
    static let automaticID = "auto"

    static let light = CodeTheme(
        id: "light", name: "Light",
        background: hex(0xF5F5F7), border: hex(0xDCDCE2), plain: hex(0x1F1F24), keyword: hex(0x9B2393),
        string: hex(0xC41A16), comment: hex(0x5D6C79), number: hex(0x1C00CF), type: hex(0x0B4F79),
        function: hex(0x326D74))
    static let dark = CodeTheme(
        id: "dark", name: "Dark",
        background: hex(0x1F1F24), border: hex(0x3A3A42), plain: hex(0xE6E6E6), keyword: hex(0xFC5FA3),
        string: hex(0xFC6A5D), comment: hex(0x7F8C98), number: hex(0xD0BF69), type: hex(0x5DD8FF),
        function: hex(0x67B7A4))
    static let solarizedLight = CodeTheme(
        id: "solarized-light", name: "Solarized Light",
        background: hex(0xFDF6E3), border: hex(0xE6DFC8), plain: hex(0x586E75), keyword: hex(0x859900),
        string: hex(0x2AA198), comment: hex(0x93A1A1), number: hex(0xD33682), type: hex(0xB58900),
        function: hex(0x268BD2))
    static let dracula = CodeTheme(
        id: "dracula", name: "Dracula",
        background: hex(0x282A36), border: hex(0x44475A), plain: hex(0xF8F8F2), keyword: hex(0xFF79C6),
        string: hex(0xF1FA8C), comment: hex(0x6272A4), number: hex(0xBD93F9), type: hex(0x8BE9FD),
        function: hex(0x50FA7B))

    static let all = [light, dark, solarizedLight, dracula]

    /// The scheme chosen in Settings; "Automatic" follows the appearance.
    static func current(for appearance: NSAppearance?) -> CodeTheme {
        resolve(UserDefaults.standard.string(forKey: Prefs.codeTheme) ?? automaticID, appearance: appearance)
    }

    static func resolve(_ id: String, appearance: NSAppearance?) -> CodeTheme {
        if let theme = all.first(where: { $0.id == id }) { return theme }
        let isDark = (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? dark : light
    }

    private static func hex(_ value: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// Code blocks are paragraphs set in Menlo; that survives RTFD, so blocks persist without extra metadata.
/// Colours are derived: `highlightAll` recomputes them on load, on edit and when the scheme changes.
enum CodeFormat {
    static let fontSize: CGFloat = 13
    static let font = NSFont(name: "Menlo-Regular", size: fontSize)
        ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    static let inset: CGFloat = 14
    static let blockSpacing: CGFloat = 10

    static func isCode(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        (attributes[.font] as? NSFont)?.familyName == "Menlo"
    }

    /// First/last paragraphs get extra spacing so the box has room above and below.
    static func paragraphStyle(first: Bool, last: Bool) -> NSParagraphStyle {
        paragraphStyles[(first ? 1 : 0) + (last ? 2 : 0)]
    }

    private static let paragraphStyles = (0..<4).map { makeParagraphStyle(first: $0 & 1 != 0, last: $0 & 2 != 0) }

    private static func makeParagraphStyle(first: Bool, last: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = inset
        style.headIndent = inset
        style.tailIndent = -inset
        style.lineSpacing = 1
        style.paragraphSpacingBefore = first ? blockSpacing : 0
        style.paragraphSpacing = last ? blockSpacing : 0
        return style
    }

    static func attributes(color: NSColor = .textColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle(first: true, last: true)]
    }

    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: DTextView.defaultFont, .foregroundColor: NSColor.textColor, .paragraphStyle: NSParagraphStyle.default]
    }

    // MARK: Detection

    private static let leadingKeywords = [
        "func ", "def ", "class ", "struct ", "enum ", "import ", "from ", "let ", "var ", "const ", "return",
        "if (", "for (", "while (", "switch ", "public ", "private ", "protected ", "static ", "#include",
        "#!/", "package ", "using ", "fn ", "impl ", "pub ", "interface ", "function ", "async ", "await ",
        "SELECT ", "INSERT ", "UPDATE ", "CREATE ", "<div", "<?php", "} else", "elif ", "except", "try:",
        "try {", "catch", "export ", "@", "for ", "while ", "echo ", "done", "fi", "then", "do", "cd ",
        "sudo ", "npm ", "git ", "brew ", "$ ",
    ]
    private static let operators = ["=>", "->", "==", "!=", "&&", "||", "::", "();", "){", "= {", "+=", "</", "/>", "[]"]

    private static func signals(_ line: String) -> Int {
        var count = 0
        if let last = line.last, ";{}()[]".contains(last) { count += 1 }
        if line.hasSuffix(":"), leadingKeywords.contains(where: line.hasPrefix) { count += 1 }
        if leadingKeywords.contains(where: line.hasPrefix) { count += 1 }
        if operators.contains(where: line.contains) { count += 1 }
        if line.hasPrefix("//") || line.hasPrefix("/*") || line.hasPrefix("* ") { count += 1 }
        if line.range(of: #"[A-Za-z_][A-Za-z0-9_.]*\("#, options: .regularExpression) != nil { count += 1 }
        return count
    }

    /// Heuristic for pasted text: most lines carry code-like signals (endings, keywords, operators, calls).
    static func looksLikeCode(_ text: String) -> Bool {
        guard text.count < 200_000 else { return false }
        let raw = text.components(separatedBy: .newlines)
        let lines = raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        if lines.count == 1 { return signals(lines[0]) >= 2 }
        let codeLines = lines.filter { signals($0) > 0 }.count
        let indented = raw.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        let proseLines = lines.filter { $0.hasSuffix(".") && $0.split(separator: " ").count > 6 }.count
        if proseLines * 2 > lines.count { return false }
        return Double(codeLines) / Double(lines.count) >= 0.4 || (indented >= 2 && codeLines >= 1)
    }

    // MARK: Highlighting

    private static let keywords: Set<String> = [
        "let", "var", "func", "def", "class", "struct", "enum", "protocol", "extension", "import", "from", "return",
        "if", "else", "elif", "for", "while", "do", "switch", "case", "break", "continue", "default", "in", "of",
        "as", "is", "try", "catch", "throw", "throws", "async", "await", "yield", "guard", "where", "public",
        "private", "protected", "internal", "static", "final", "const", "fn", "mut", "pub", "use", "mod", "impl",
        "trait", "match", "new", "delete", "this", "self", "super", "nil", "null", "None", "true", "false", "True",
        "False", "void", "int", "float", "double", "bool", "string", "char", "long", "short", "unsigned", "auto",
        "typedef", "sizeof", "package", "interface", "extends", "implements", "function", "lambda", "with", "pass",
        "raise", "except", "finally", "not", "and", "or", "echo", "then", "fi", "done", "esac", "local", "export",
        "readonly", "type", "go", "defer", "chan", "select", "struct", "undefined", "typeof", "instanceof",
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "UPDATE", "DELETE", "JOIN", "ON", "GROUP", "BY", "ORDER",
        "AS", "AND", "OR", "NOT", "NULL", "CREATE", "TABLE", "VALUES", "SET", "LIMIT", "LEFT", "INNER",
    ]

    /// Leftmost-first alternation, so comment markers inside strings (and vice versa) are handled.
    private static let tokenizer = try! NSRegularExpression(
        pattern: [
            // 1: comments
            #"(//[^\n]*|/\*[\s\S]*?\*/|(?:^|(?<=[ \t]))#(?!include|define|import|ifn?def|if\b|endif|pragma|else|elif)[^\n]*|(?:^|(?<=[ \t]))--[ \t][^\n]*)"#,
            // 2: strings
            #"("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`[^`]*`)"#,
            // 3: numbers
            #"(\b(?:0[xX][0-9A-Fa-f]+|\d+(?:\.\d+)?)\b)"#,
            // 4: words (and #directives)
            #"(#?[A-Za-z_][A-Za-z0-9_]*)"#,
        ].joined(separator: "|"),
        options: [.anchorsMatchLines])

    /// Re-applies code formatting and colours to every code block in `storage`.
    static func highlightAll(_ storage: NSTextStorage, theme: CodeTheme) {
        storage.beginEditing()
        highlight(storage, around: nil, theme: theme)
        storage.endEditing()
    }

    /// Formats the code blocks touching `range` (nil = whole text), plus the paragraphs either side so
    /// merged, split or removed blocks get the right ends. Only attributes that differ are written, so
    /// untouched blocks are not laid out again (no flicker). Safe to call from `willProcessEditing`.
    static func highlight(_ storage: NSTextStorage, around range: NSRange?, theme: CodeTheme) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        func paragraph(at location: Int) -> NSRange {
            ns.paragraphRange(for: NSRange(location: min(max(location, 0), ns.length), length: 0))
        }
        func isCodeParagraph(at location: Int) -> Bool {
            let start = paragraph(at: location).location
            return start < ns.length && isCode(storage.attributes(at: start, effectiveRange: nil))
        }

        var scan = NSRange(location: 0, length: ns.length)
        if let range {
            var start = paragraph(at: range.location).location
            var end = NSMaxRange(paragraph(at: NSMaxRange(range)))
            if start > 0 { start = paragraph(at: start - 1).location }
            while start > 0, isCodeParagraph(at: start - 1) { start = paragraph(at: start - 1).location }
            if end < ns.length { end = NSMaxRange(paragraph(at: end)) }
            while end < ns.length, isCodeParagraph(at: end) { end = NSMaxRange(paragraph(at: end)) }
            scan = NSRange(location: start, length: end - start)
        }

        var blocks: [[NSRange]] = []
        var current: [NSRange] = []
        ns.enumerateSubstrings(in: scan, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            if enclosing.length > 0, isCode(storage.attributes(at: enclosing.location, effectiveRange: nil)) {
                current.append(enclosing)
            } else if !current.isEmpty {
                blocks.append(current)
                current = []
            }
        }
        if !current.isEmpty { blocks.append(current) }

        for paragraphs in blocks {
            for (i, paragraph) in paragraphs.enumerated() {
                set(storage, .paragraphStyle, paragraphStyle(first: i == 0, last: i == paragraphs.count - 1), in: paragraph)
                set(storage, .font, font, in: paragraph)
            }
            colorize(storage, block: NSUnionRange(paragraphs[0], paragraphs[paragraphs.count - 1]), ns: ns, theme: theme)
        }
    }

    /// Sets `key` to `value` only on the runs where it differs.
    private static func set(_ storage: NSTextStorage, _ key: NSAttributedString.Key, _ value: NSObject?, in range: NSRange) {
        var changes: [NSRange] = []
        storage.enumerateAttribute(key, in: range) { existing, run, _ in
            if (existing as? NSObject) != value { changes.append(run) }
        }
        for run in changes {
            if let value { storage.addAttribute(key, value: value, range: run) } else { storage.removeAttribute(key, range: run) }
        }
    }

    private static func colorize(_ storage: NSTextStorage, block: NSRange, ns: NSString, theme: CodeTheme) {
        set(storage, .backgroundColor, nil, in: block)
        var location = block.location
        func paint(_ range: NSRange, _ color: NSColor) { set(storage, .foregroundColor, color, in: range) }
        for match in tokenizer.matches(in: storage.string, range: block) {
            let color: NSColor
            if match.range(at: 1).location != NSNotFound {
                color = theme.comment
            } else if match.range(at: 2).location != NSNotFound {
                color = theme.string
            } else if match.range(at: 3).location != NSNotFound {
                color = theme.number
            } else {
                let word = ns.substring(with: match.range)
                if word.hasPrefix("#") || keywords.contains(word) {
                    color = theme.keyword
                } else if word.first?.isUppercase == true {
                    color = theme.type
                } else if isFollowedByParen(ns, after: NSMaxRange(match.range)) {
                    color = theme.function
                } else {
                    color = theme.plain
                }
            }
            if match.range.location > location {
                paint(NSRange(location: location, length: match.range.location - location), theme.plain)
            }
            paint(match.range, color)
            location = NSMaxRange(match.range)
        }
        if location < NSMaxRange(block) {
            paint(NSRange(location: location, length: NSMaxRange(block) - location), theme.plain)
        }
    }

    private static func isFollowedByParen(_ ns: NSString, after index: Int) -> Bool {
        var i = index
        while i < ns.length, ns.character(at: i) == 32 { i += 1 }
        return i < ns.length && ns.character(at: i) == 40
    }

    /// Standalone highlighted sample, for the Settings preview.
    static func highlighted(_ code: String, theme: CodeTheme) -> NSAttributedString {
        let storage = NSTextStorage(string: code, attributes: attributes(color: theme.plain))
        highlightAll(storage, theme: theme)
        return storage
    }

    /// v0.1/v0.2 pages stored the default text colour as black; make those runs follow the appearance again.
    static func normalizeTextColors(_ storage: NSTextStorage) {
        var fixes: [NSRange] = []
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else {
                fixes.append(range)
                return
            }
            if color.redComponent < 0.15, color.greenComponent < 0.15, color.blueComponent < 0.15,
               color.alphaComponent > 0.9 {
                fixes.append(range)
            }
        }
        guard !fixes.isEmpty else { return }
        storage.beginEditing()
        for range in fixes { storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range) }
        storage.endEditing()
    }
}

/// Draws the box behind a code paragraph. Consecutive code paragraphs join into one box;
/// only the first and last get rounded ends (marked by their paragraph spacing).
final class CodeBlockFragment: NSTextLayoutFragment {
    private var style: NSParagraphStyle? {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return nil }
        return paragraph.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    }

    private var boxRect: CGRect {
        // Skip the empty virtual line TextKit 2 adds after a final newline, so it sits outside the box.
        let lines = textLineFragments.filter { $0.characterRange.length > 0 }
        guard let firstLine = lines.first, let lastLine = lines.last else { return .zero }
        let isFirst = (style?.paragraphSpacingBefore ?? 0) > 0
        let isLast = (style?.paragraphSpacing ?? 0) > 0
        // Joined edges run to the fragment's edges (+1pt overlap) so adjacent paragraphs leave no seam.
        let top = isFirst ? firstLine.typographicBounds.minY - 6 : -1
        let bottom = isLast ? lastLine.typographicBounds.maxY + 6 : layoutFragmentFrame.height + 1
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        return CGRect(x: 4 - layoutFragmentFrame.minX, y: top, width: max(0, width - 8), height: bottom - top)
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(boxRect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = boxRect.offsetBy(dx: point.x, dy: point.y)
        let isFirst = (style?.paragraphSpacingBefore ?? 0) > 0
        let isLast = (style?.paragraphSpacing ?? 0) > 0
        // Round only the block's outer ends: extend the shape past joined edges, then clip.
        var shape = rect
        if !isFirst { shape.origin.y -= 12; shape.size.height += 12 }
        if !isLast { shape.size.height += 12 }
        let theme = CodeTheme.current(for: NSAppearance.currentDrawing())
        context.saveGState()
        context.clip(to: rect)
        let path = CGPath(roundedRect: shape, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.setFillColor(theme.background.cgColor)
        context.fillPath()
        context.addPath(CGPath(roundedRect: shape.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.setStrokeColor(theme.border.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
