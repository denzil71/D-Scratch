import AppKit
import Carbon.HIToolbox

/// The global Quick Capture shortcut, picked from a few presets in Settings › Capture.
struct CaptureShortcut: Identifiable {
    let id: String
    let label: String
    let keyCode: UInt32
    /// Carbon modifier flags.
    let modifiers: UInt32

    static let offID = "off"
    static let defaultID = "ctrlOptSpace"

    static let all = [
        CaptureShortcut(id: "ctrlOptSpace", label: "⌃⌥Space", keyCode: UInt32(kVK_Space),
                        modifiers: UInt32(controlKey | optionKey)),
        CaptureShortcut(id: "ctrlOptN", label: "⌃⌥N", keyCode: UInt32(kVK_ANSI_N),
                        modifiers: UInt32(controlKey | optionKey)),
        CaptureShortcut(id: "ctrlOptCmdN", label: "⌃⌥⌘N", keyCode: UInt32(kVK_ANSI_N),
                        modifiers: UInt32(controlKey | optionKey | cmdKey)),
        CaptureShortcut(id: "ctrlOptCmdSpace", label: "⌃⌥⌘Space", keyCode: UInt32(kVK_Space),
                        modifiers: UInt32(controlKey | optionKey | cmdKey)),
    ]

    /// The shortcut chosen in Settings; nil when it's off.
    static var current: CaptureShortcut? {
        let id = UserDefaults.standard.string(forKey: Prefs.captureShortcut) ?? defaultID
        return all.first { $0.id == id }
    }
}

/// A system-wide hot key (Carbon `RegisterEventHotKey`, which needs no Accessibility permission).
@MainActor
final class GlobalHotKey: ObservableObject {
    static let shared = GlobalHotKey()

    var onPress: (() -> Void)?
    /// True when the chosen shortcut couldn't be registered, usually because another app has it.
    @Published private(set) var failed = false
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    /// (Re-)registers the shortcut chosen in Settings.
    func apply() {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        failed = false
        guard let shortcut = CaptureShortcut.current else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x4453_4352), id: 1)  // "DSCR"
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            ref = nil
            failed = true
            NSLog("D-Scratch: couldn't register \(shortcut.label) (\(status))")
        }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// The "New D-Scratch Page from Selection" item in other apps' Services menus (declared in Info.plist).
@MainActor
final class CaptureService: NSObject {
    @objc func newPageFromSelection(
        _ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let richTypes: [NSPasteboard.PasteboardType] = [.rtfd, .rtf, .html]
        var text: NSAttributedString?
        if pboard.availableType(from: richTypes) != nil {
            text = pboard.readObjects(forClasses: [NSAttributedString.self])?.first as? NSAttributedString
        }
        if text == nil, let string = pboard.string(forType: .string) {
            text = NSAttributedString(string: string, attributes: CodeFormat.bodyAttributes)
        }
        guard let text, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "There's no text selected to send to D-Scratch." as NSString
            return
        }
        QuickCapture.shared.show(prefill: text)
    }
}

/// The floating Quick Capture panel: an optional title, a note and where to save it.
/// It doesn't activate D-Scratch, so the app you were using stays in front.
@MainActor
final class QuickCapture: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = QuickCapture()

    /// Set once the main window appears; a capture asked for before then waits.
    weak var store: Store? {
        didSet {
            guard store != nil, pendingShow else { return }
            pendingShow = false
            show(prefill: pendingText)
            pendingText = nil
        }
    }

    private var pendingShow = false
    private var pendingText: NSAttributedString?
    private var panel: NSPanel?
    private let titleField = NSTextField()
    private let textView = CaptureTextView()
    private let destination = NSPopUpButton()

    /// Opens the panel, empty or holding `prefill` (text sent from another app).
    func show(prefill: NSAttributedString? = nil) {
        guard let store else {
            pendingShow = true
            pendingText = prefill ?? pendingText
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible || prefill != nil {
            titleField.stringValue = ""
            textView.textStorage?.setAttributedString(prefill ?? NSAttributedString())
            textView.typingAttributes = CodeFormat.bodyAttributes
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            textView.scrollToEndOfDocument(nil)
            reloadDestinations(store)
            position(panel)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(prefill == nil ? textView : titleField)
    }

    @objc private func save() {
        guard let store, let panel else { return }
        let text = NSMutableAttributedString(attributedString: textView.attributedString())
        while text.string.last.map({ $0.isWhitespace || $0.isNewline }) == true {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
        let typedTitle = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.length > 0 || !typedTitle.isEmpty else {
            NSSound.beep()
            return
        }
        let choice = destination.selectedItem?.representedObject as? String ?? Store.inboxDestination
        UserDefaults.standard.set(choice, forKey: Prefs.captureDestination)
        store.addCapturedPage(
            title: typedTitle.isEmpty ? Self.title(from: text.string) : typedTitle,
            content: Store.capturedContent(text), destination: choice)
        panel.orderOut(nil)
    }

    @objc private func cancel() {
        panel?.orderOut(nil)
    }

    /// The first line of the note, shortened; or a dated title when there's no text.
    static func title(from text: String) -> String {
        let firstLine = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            .components(separatedBy: .newlines)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let firstLine else {
            return "Capture " + Date().formatted(date: .abbreviated, time: .shortened)
        }
        return firstLine.count > 60 ? String(firstLine.prefix(59)) + "…" : firstLine
    }

    // MARK: Destinations

    /// "Inbox" (until that group exists, after which it's listed with the others), "Top Level", then every group.
    private func reloadDestinations(_ store: Store) {
        let menu = NSMenu()
        func add(_ title: String, _ value: String, indent: Int = 0) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = value
            item.indentationLevel = indent
            menu.addItem(item)
        }
        if store.inboxGroup == nil { add("Inbox", Store.inboxDestination) }
        add("Top Level", Store.topLevelDestination)
        let tree = store.groupTree()
        if !tree.isEmpty { menu.addItem(.separator()) }
        for (group, depth) in tree { add(group.name, group.id.uuidString, indent: depth) }
        destination.menu = menu

        var saved = UserDefaults.standard.string(forKey: Prefs.captureDestination) ?? Store.inboxDestination
        if saved == Store.inboxDestination, let inbox = store.inboxGroup { saved = inbox.id.uuidString }
        let match = menu.items.first { $0.representedObject as? String == saved }
            ?? menu.items.first { $0.representedObject as? String == Store.inboxDestination }
            ?? store.inboxGroup.flatMap { inbox in menu.items.first { $0.representedObject as? String == inbox.id.uuidString } }
        destination.select(match ?? menu.items.first)
    }

    // MARK: Panel

    private func makePanel() -> NSPanel {
        let panel = CapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.title = "Quick Capture"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 360, height: 200)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancel() }

        titleField.placeholderString = "Title (optional — the first line is used otherwise)"
        titleField.delegate = self
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none

        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.font = DTextView.defaultFont
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onSubmit = { [weak self] in self?.save() }
        textView.onCancel = { [weak self] in self?.cancel() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 452, height: 160))
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        textView.drawsBackground = false

        let divider = NSBox()
        divider.boxType = .separator

        destination.controlSize = .small
        destination.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let saveTo = NSTextField(labelWithString: "Save to")
        saveTo.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        saveTo.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: "↩ Save   ⇧↩ New line   esc Cancel")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .tertiaryLabelColor
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelColor = .controlAccentColor
        saveButton.controlSize = .small

        let footer = NSStackView(views: [saveTo, destination, NSView(), hint, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.setHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [titleField, divider, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for view in [titleField, divider, scroll, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        panel.contentView = stack
        return panel
    }

    /// Centred a little above the middle of the screen the pointer is on.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + area.height / 8))
    }

    // MARK: Title field keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            save()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }
}

/// Escape closes the panel even when no control handles it.
private final class CapturePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Return saves; Shift-Return or Option-Return adds a line; Escape cancels.
private final class CaptureTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func insertNewline(_ sender: Any?) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) || flags.contains(.option) {
            super.insertNewline(sender)
        } else {
            onSubmit?()
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
