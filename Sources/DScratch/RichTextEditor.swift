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
        textView.usesAdaptiveColorMappingForDarkAppearance = true
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
        if let content = store.loadContent(pageID) {
            textView.textStorage?.setAttributedString(content)
            if let storage = textView.textStorage { MediaAttachment.upgrade(storage) }
        } else {
            coordinator.canSave = false
            textView.isEditable = false
            textView.string = "This page could not be read."
        }
        textView.pageID = pageID
        textView.delegate = coordinator
        coordinator.textView = textView
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
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.apply(reveal)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.saveNow()
        coordinator.store.unregisterFlush(coordinator.pageID, owner: coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let pageID: UUID
        let store: Store
        weak var textView: DTextView?
        var canSave = true
        private var dirty = false
        private var timer: Timer?
        private var lastReveal: UUID?

        init(pageID: UUID, store: Store) {
            self.pageID = pageID
            self.store = store
        }

        func textDidChange(_ notification: Notification) {
            dirty = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveNow() }
            }
            // Deferred so the edit that added the attachment finishes first.
            DispatchQueue.main.async { [weak self] in
                if let storage = self?.textView?.textStorage { MediaAttachment.upgrade(storage) }
            }
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
            store.saveContent(pageID, NSAttributedString(attributedString: storage))
            dirty = false
        }
    }
}
