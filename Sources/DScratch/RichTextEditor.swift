import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class DTextView: NSTextView {
    static let defaultFont = NSFont.systemFont(ofSize: 14)

    var pageID: UUID?

    /// Appends a question/answer block at the end of the page as one undoable edit.
    func appendClaudeAnswer(question: String, answer: String) {
        let body: [NSAttributedString.Key: Any] = [.font: Self.defaultFont, .foregroundColor: NSColor.textColor]
        let block = NSMutableAttributedString()
        if !string.isEmpty && !string.hasSuffix("\n") {
            block.append(NSAttributedString(string: "\n", attributes: body))
        }
        block.append(NSAttributedString(
            string: "Claude: \(question)\n",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: Self.defaultFont.pointSize),
                .foregroundColor: NSColor.systemPurple,
            ]))
        block.append(MarkdownRenderer.render(answer))
        block.append(NSAttributedString(string: "\n\n", attributes: body))
        let end = NSRange(location: (string as NSString).length, length: 0)
        insertText(block, replacementRange: end)
        scrollRangeToVisible(NSRange(location: (string as NSString).length, length: 0))
    }

    // MARK: Code blocks

    /// Called when light/dark changes, so code colours can follow an "Automatic" scheme.
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    private func isCode(at location: Int) -> Bool {
        guard let storage = textStorage, location >= 0, location < storage.length else { return false }
        return CodeFormat.isCode(storage.attributes(at: location, effectiveRange: nil))
    }

    /// Runs of non-space text with a letter or digit, so "state-of-the-art" is one word (as in Pages and Word).
    private static let wordPattern = try! NSRegularExpression(pattern: "\\S*[\\p{L}\\p{N}]\\S*")

    /// Words on the page, not counting code blocks.
    var proseWordCount: Int {
        guard let storage = textStorage else { return 0 }
        return Self.wordPattern.matches(in: string, range: NSRange(location: 0, length: storage.length))
            .filter { !CodeFormat.isCode(storage.attributes(at: $0.range.location, effectiveRange: nil)) }
            .count
    }

    private var currentParagraph: NSRange {
        (string as NSString).paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
    }

    /// Pasted code goes into a code block; pasting inside a block keeps it plain code.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let hasMedia = pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
            || pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        guard !hasMedia, let text = pasteboard.string(forType: .string) else { return super.paste(sender) }
        if isCode(at: currentParagraph.location) {
            insertText(NSAttributedString(string: text, attributes: CodeFormat.attributes()), replacementRange: selectedRange())
        } else if CodeFormat.looksLikeCode(text) {
            insertCodeBlock(text, replacing: selectedRange())
        } else {
            super.paste(sender)
        }
    }

    /// Inserts `code` as its own block of paragraphs, followed by normal text.
    func insertCodeBlock(_ code: String, replacing range: NSRange) {
        let ns = string as NSString
        var text = code.replacingOccurrences(of: "\r\n", with: "\n")
        while text.hasSuffix("\n") || text.hasSuffix(" ") { text.removeLast() }
        while text.hasPrefix("\n") { text.removeFirst() }
        let block = NSMutableAttributedString()
        if range.location > 0 && ns.character(at: range.location - 1) != 10 {
            block.append(NSAttributedString(string: "\n", attributes: CodeFormat.bodyAttributes))
        }
        block.append(NSAttributedString(string: text + "\n", attributes: CodeFormat.attributes()))
        insertText(block, replacementRange: range)
        typingAttributes = CodeFormat.bodyAttributes
    }

    /// Format › Code Block: turns the selected paragraphs into a code block, or back into text.
    @objc func toggleCodeBlock(_ sender: Any?) {
        guard let storage = textStorage else { return }
        let paragraphs = (string as NSString).paragraphRange(for: selectedRange())
        guard paragraphs.length > 0 else {
            typingAttributes = CodeFormat.isCode(typingAttributes) ? CodeFormat.bodyAttributes : CodeFormat.attributes()
            return
        }
        var allCode = true
        (string as NSString).enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) {
            _, _, enclosing, _ in
            if !self.isCode(at: enclosing.location) { allCode = false }
        }
        guard shouldChangeText(in: paragraphs, replacementString: nil) else { return }
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: paragraphs)
        storage.addAttributes(allCode ? CodeFormat.bodyAttributes : CodeFormat.attributes(), range: paragraphs)
        storage.endEditing()
        didChangeText()
        // A style-only change isn't rechecked, so update the misspelling marks here.
        if allCode {
            checkText(in: paragraphs, types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: [:])
        } else {
            setSpellingState(0, range: paragraphs)
        }
    }

    // MARK: Spelling

    /// Code isn't prose: drop misspellings found inside code blocks.
    override func handleTextCheckingResults(
        _ results: [NSTextCheckingResult], forRange range: NSRange, types checkingTypes: NSTextCheckingTypes,
        options: [NSSpellChecker.OptionKey: Any] = [:], orthography: NSOrthography, wordCount: Int
    ) {
        let prose = results.filter { $0.resultType != .spelling || !isCode(at: $0.range.location) }
        super.handleTextCheckingResults(
            prose, forRange: range, types: checkingTypes, options: options, orthography: orthography, wordCount: wordCount)
    }

    /// AppKit's menu already lists corrections for a misspelled word; its "Learn Spelling" gets a clearer name.
    /// It checks the clicked word itself, so in code its spelling items are removed.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let spellingActions = ["_changeSpellingFromMenu:", "_ignoreSpellingFromMenu:", "_learnSpellingFromMenu:"]
        let clicked = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if isCode(at: clicked) {
            for item in menu.items where spellingActions.contains(item.action.map(NSStringFromSelector) ?? "") {
                menu.removeItem(item)
            }
            while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        } else {
            menu.items.first { $0.action.map(NSStringFromSelector) == "_learnSpellingFromMenu:" }?.title = "Add to Dictionary"
        }
        return menu
    }

    /// Typing outside a code block must not continue in code (e.g. on the empty line after a block).
    func syncTypingAttributes() {
        guard selectedRange().length == 0, CodeFormat.isCode(typingAttributes) else { return }
        let paragraph = currentParagraph
        if paragraph.length == 0 || !isCode(at: paragraph.location) {
            typingAttributes = CodeFormat.bodyAttributes
        }
    }

    /// Absolute character ranges of the visual lines of the paragraph containing `location`.
    /// Excludes the empty virtual line TextKit 2 appends to the last paragraph after a final newline.
    private func lineRanges(ofParagraphAt location: Int) -> [NSRange] {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let textLocation = tcm.location(tcm.documentRange.location, offsetBy: location),
              let fragment = tlm.textLayoutFragment(for: textLocation) else { return [] }
        let start = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
        return fragment.textLineFragments.filter { $0.characterRange.length > 0 }.map {
            NSRange(location: start + $0.characterRange.location, length: $0.characterRange.length)
        }
    }

    /// The first paragraph is code, so there is no text line above it.
    private var codeBlockAtTop: Bool { isCode(at: 0) }

    /// The page ends with a code block. The virtual line after a final newline doesn't count:
    /// TextKit 2 draws its caret inside the block, so a real text line is added instead.
    private var codeBlockAtBottom: Bool {
        let length = (string as NSString).length
        return length > 0 && isCode(at: (string as NSString).paragraphRange(
            for: NSRange(location: length - 1, length: 0)).location)
    }

    private func addTextLineAbove() {
        insertText(NSAttributedString(string: "\n", attributes: CodeFormat.bodyAttributes),
                   replacementRange: NSRange(location: 0, length: 0))
        setSelectedRange(NSRange(location: 0, length: 0))
        typingAttributes = CodeFormat.bodyAttributes
    }

    /// Ends the block's last line if needed, then adds an empty text paragraph and puts the caret on it.
    private func addTextLineBelow() {
        let length = (string as NSString).length
        let addition = NSMutableAttributedString()
        if !string.hasSuffix("\n") {
            addition.append(NSAttributedString(string: "\n", attributes: CodeFormat.attributes()))
        }
        addition.append(NSAttributedString(string: "\n", attributes: CodeFormat.bodyAttributes))
        insertText(addition, replacementRange: NSRange(location: length, length: 0))
        setSelectedRange(NSRange(location: (string as NSString).length - 1, length: 0))
        typingAttributes = CodeFormat.bodyAttributes
    }

    override func moveUp(_ sender: Any?) {
        let caret = selectedRange()
        if caret.length == 0, codeBlockAtTop,
           let firstLine = lineRanges(ofParagraphAt: 0).first, caret.location <= NSMaxRange(firstLine) {
            return addTextLineAbove()
        }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        let caret = selectedRange()
        let length = (string as NSString).length
        // Below a final newline the caret is already past the block.
        let inBlock = caret.location < length || !string.hasSuffix("\n")
        if caret.length == 0, codeBlockAtBottom, inBlock,
           let lastLine = lineRanges(ofParagraphAt: max(0, length - 1)).last, caret.location >= lastLine.location {
            return addTextLineBelow()
        }
        super.moveDown(sender)
    }

    /// Clicking above a block at the top, or below a block at the bottom, adds a text line there.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, let tlm = textLayoutManager {
            let origin = textContainerOrigin
            let docStart = tlm.documentRange.location
            if codeBlockAtTop, let first = tlm.textLayoutFragment(for: docStart),
               point.y < origin.y + first.layoutFragmentFrame.minY + CodeFormat.blockSpacing - 6 {
                window?.makeFirstResponder(self)
                return addTextLineAbove()
            }
            if codeBlockAtBottom, point.y > origin.y + tlm.usageBoundsForTextContainer.maxY {
                window?.makeFirstResponder(self)
                return addTextLineBelow()
            }
        }
        super.mouseDown(with: event)
    }

    /// "```" + Return starts a code block; Return on an empty last line of a block leaves it.
    override func insertNewline(_ sender: Any?) {
        guard let storage = textStorage, selectedRange().length == 0 else { return super.insertNewline(sender) }
        let ns = string as NSString
        let paragraph = currentParagraph
        let line = ns.substring(with: paragraph).trimmingCharacters(in: .newlines)

        if isCode(at: paragraph.location), NSMaxRange(paragraph) == ns.length, !string.hasSuffix("\n"),
           selectedRange().location == ns.length {
            // New line at the very end of a final block stays in the block.
            insertText(NSAttributedString(string: "\n", attributes: CodeFormat.attributes()), replacementRange: selectedRange())
            typingAttributes = CodeFormat.attributes()
            return
        }

        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```"), !isCode(at: paragraph.location) {
            insertText(NSAttributedString(string: "\n", attributes: CodeFormat.attributes()), replacementRange: paragraph)
            setSelectedRange(NSRange(location: paragraph.location, length: 0))
            typingAttributes = CodeFormat.attributes()
            return
        }

        let previousIsCode = paragraph.location > 0 && isCode(at: paragraph.location - 1)
        if line.isEmpty && paragraph.length == 0 && previousIsCode && CodeFormat.isCode(typingAttributes) {
            // Empty last line at the end of the document.
            typingAttributes = CodeFormat.bodyAttributes
            return
        }
        if line.isEmpty, isCode(at: paragraph.location), previousIsCode, !isCode(at: NSMaxRange(paragraph)) {
            if shouldChangeText(in: paragraph, replacementString: nil) {
                storage.setAttributes(CodeFormat.bodyAttributes, range: paragraph)
                didChangeText()
            }
            typingAttributes = CodeFormat.bodyAttributes
            return
        }
        super.insertNewline(sender)
    }

    @objc func toggleBold(_ sender: Any?) { toggle(.boldFontMask) }
    @objc func toggleItalic(_ sender: Any?) { toggle(.italicFontMask) }

    @objc func toggleUnderline(_ sender: Any?) {
        let range = selectedRange()
        guard let storage = textStorage else { return }
        if range.length == 0 {
            let on = (typingAttributes[.underlineStyle] as? Int ?? 0) != 0
            typingAttributes[.underlineStyle] = on ? 0 : NSUnderlineStyle.single.rawValue
            return
        }
        var allOn = true
        storage.enumerateAttribute(.underlineStyle, in: range) { value, _, _ in
            if (value as? Int ?? 0) == 0 { allOn = false }
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if allOn {
            storage.removeAttribute(.underlineStyle, range: range)
        } else {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        storage.endEditing()
        didChangeText()
    }

    private func toggle(_ trait: NSFontTraitMask) {
        let fm = NSFontManager.shared
        let range = selectedRange()
        guard let storage = textStorage else { return }
        if range.length == 0 {
            let font = typingAttributes[.font] as? NSFont ?? Self.defaultFont
            let has = fm.traits(of: font).contains(trait)
            typingAttributes[.font] = has ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait)
            return
        }
        var allHave = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            if !fm.traits(of: value as? NSFont ?? Self.defaultFont).contains(trait) { allHave = false }
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? Self.defaultFont
            let converted = allHave ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: subrange)
        }
        storage.endEditing()
        didChangeText()
    }

    @objc func insertMedia(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .audio]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images, video or audio to insert"
        guard panel.runModal() == .OK else { return }
        let result = NSMutableAttributedString()
        for url in panel.urls {
            guard let kind = MediaAttachment.kind(forFilename: url.lastPathComponent),
                  let wrapper = try? FileWrapper(url: url, options: .immediate) else { continue }
            wrapper.preferredFilename = url.lastPathComponent
            result.append(NSAttributedString(attachment: MediaAttachment(fileWrapper: wrapper, kind: kind)))
            result.append(NSAttributedString(string: "\n", attributes: typingAttributes))
        }
        guard result.length > 0 else { return }
        window?.makeFirstResponder(self)
        insertText(result, replacementRange: selectedRange())
    }
}

struct RichTextEditor: NSViewRepresentable {
    let pageID: UUID
    let store: Store
    /// A search hit to select and scroll to.
    let reveal: Reveal?
    /// Reports the page's word count (code blocks excluded) on load and after edits.
    var onWordCount: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(pageID: pageID, store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = DTextView(usingTextLayoutManager: true)
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.usesInspectorBar = true
        textView.usesFindBar = true
        textView.usesFontPanel = true
        textView.usesRuler = true
        textView.isContinuousSpellCheckingEnabled = true
        // Off so code-scheme colours draw exactly; default text uses the dynamic textColor instead.
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = [.font: DTextView.defaultFont, .foregroundColor: NSColor.textColor]

        let coordinator = context.coordinator
        coordinator.onWordCount = onWordCount
        if let content = store.loadContent(pageID) {
            textView.textStorage?.setAttributedString(content)
            if let storage = textView.textStorage {
                MediaAttachment.upgrade(storage)
                CodeFormat.normalizeTextColors(storage)
            }
        } else {
            coordinator.canSave = false
            textView.isEditable = false
            textView.string = "This page could not be read."
        }
        textView.pageID = pageID
        textView.delegate = coordinator
        textView.textLayoutManager?.delegate = coordinator
        coordinator.textView = textView
        coordinator.rehighlight()
        textView.textStorage?.delegate = coordinator
        textView.onAppearanceChange = { [weak coordinator] in coordinator?.rehighlight() }
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.themeChanged), name: CodeTheme.changedNotification, object: nil)
        store.activeTextView = textView
        store.registerFlush(pageID, owner: coordinator) { [weak coordinator] in coordinator?.saveNow() }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        }
        coordinator.apply(reveal)
        // Deferred: SwiftUI state can't change while this view is being made.
        DispatchQueue.main.async { coordinator.countWords() }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onWordCount = onWordCount
        context.coordinator.apply(reveal)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.saveNow()
        coordinator.store.unregisterFlush(coordinator.pageID, owner: coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextLayoutManagerDelegate, NSTextStorageDelegate {
        let pageID: UUID
        let store: Store
        weak var textView: DTextView?
        var canSave = true
        var onWordCount: (Int) -> Void = { _ in }
        private var dirty = false
        private var timer: Timer?
        private var countTimer: Timer?
        private var lastReveal: UUID?

        /// The data generation this editor loaded from; after a restore its saves are ignored.
        let generation: Int

        init(pageID: UUID, store: Store) {
            self.pageID = pageID
            self.store = store
            generation = store.dataGeneration
        }

        func textDidChange(_ notification: Notification) {
            dirty = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveNow() }
            }
            // Recounted once typing pauses, so long pages aren't rescanned on every keystroke.
            countTimer?.invalidate()
            countTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.countWords() }
            }
            // Deferred so the edit that added the attachment finishes first.
            // (Code is highlighted inside the edit itself, in `willProcessEditing`.)
            DispatchQueue.main.async { [weak self] in
                if let storage = self?.textView?.textStorage { MediaAttachment.upgrade(storage) }
            }
        }

        /// Highlights as part of each edit, so the colour changes join that edit's undo step and only
        /// the edited block is laid out again.
        nonisolated func textStorage(
            _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange, changeInLength delta: Int
        ) {
            MainActor.assumeIsolated {
                guard !isHighlightingAll else { return }
                CodeFormat.highlight(textStorage, around: editedRange, theme: theme)
            }
        }

        func countWords() {
            guard let textView else { return }
            onWordCount(textView.proseWordCount)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.syncTypingAttributes()
        }

        private var isHighlightingAll = false
        private var theme = CodeTheme.light

        /// Whole-page pass: on open, and when the scheme or appearance changes.
        func rehighlight() {
            guard let textView, let storage = textView.textStorage else { return }
            theme = CodeTheme.current(for: textView.effectiveAppearance)
            isHighlightingAll = true
            CodeFormat.highlightAll(storage, theme: theme)
            isHighlightingAll = false
            textView.needsDisplay = true
        }

        @objc func themeChanged() { rehighlight() }

        nonisolated func textLayoutManager(
            _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
            in textElement: NSTextElement
        ) -> NSTextLayoutFragment {
            if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
               CodeFormat.isCode(paragraph.attributedString.attributes(at: 0, effectiveRange: nil)) {
                return CodeBlockFragment(textElement: textElement, range: textElement.elementRange)
            }
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }

        func apply(_ reveal: Reveal?) {
            guard let reveal, reveal.pageID == pageID, reveal.token != lastReveal else { return }
            lastReveal = reveal.token
            // Deferred past the initial layout and cursor placement.
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView else { return }
                let length = (textView.string as NSString).length
                let location = min(reveal.range.location, length)
                let range = NSRange(location: location, length: min(reveal.range.length, length - location))
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
                textView.showFindIndicator(for: range)
                self.store.pendingReveal = nil
            }
        }

        func saveNow() {
            timer?.invalidate()
            guard dirty, canSave, let storage = textView?.textStorage else { return }
            store.saveContent(pageID, NSAttributedString(attributedString: storage), generation: generation)
            dirty = false
        }
    }
}
