import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct PageMeta: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var isLocked = false
    /// Set only on pages locked by v0.1 with their own password; nil once moved to the master password.
    var salt: Data?
    /// nil = not in a group.
    var groupID: UUID?

    var isLegacyLocked: Bool { isLocked && salt != nil }
}

struct PageGroup: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var isExpanded = true
}

/// The master password wraps a random data key; locked pages are encrypted with the data key,
/// so changing the password only re-wraps the key.
struct VaultFile: Codable {
    var salt: Data
    var wrappedKey: Data
}

struct SearchHit: Identifiable {
    let id = UUID()
    let pageID: UUID
    let snippet: AttributedString
    /// nil for a title match.
    let range: NSRange?
}

struct Reveal: Equatable {
    let token = UUID()
    let pageID: UUID
    let range: NSRange
}

enum Prefs {
    static let autoLockMinutes = "autoLockMinutes"
    static let claudeModel = "claudeModel"
    static let claudeIncludePage = "claudeIncludePage"
    static let codeTheme = "codeTheme"
    /// "claudeCode" (Claude account via the Claude Code CLI) or "api" (API key).
    static let claudeBackend = "claudeBackend"
    static let claudeCodeModel = "claudeCodeModel"
    static let claudeUseCaveman = "claudeUseCaveman"
    static let defaultModel = "claude-opus-5-5"
}

/// Owns the page list and all reads/writes to disk.
/// Layout: ~/Library/Application Support/D-Scratch/{index.json, groups.json, vault.json, pages/<id>.page | <id>.locked}
@MainActor
final class Store: ObservableObject {
    /// Order within this array is the sidebar order within each group.
    @Published var pages: [PageMeta] = []
    @Published var groups: [PageGroup] = []
    @Published var selection: UUID?
    /// A page or group being renamed.
    @Published var renamingID: UUID?
    @Published var pendingReveal: Reveal?
    @Published private(set) var hasMasterPassword = false
    @Published private(set) var isUnlocked = false

    /// Text view of the page currently on screen.
    weak var activeTextView: DTextView?

    private var vault: VaultFile?
    private var dataKey: SymmetricKey?
    private var lastActivity = Date()
    private var textCache: [UUID: String] = [:]
    private var flushers: [UUID: (owner: ObjectIdentifier, flush: () -> Void)] = [:]
    private let root: URL
    private var pagesDir: URL { root.appendingPathComponent("pages", isDirectory: true) }
    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var groupsURL: URL { root.appendingPathComponent("groups.json") }
    private var vaultURL: URL { root.appendingPathComponent("vault.json") }

    /// `root` (or the DSCRATCH_DATA_DIR environment variable) overrides the data folder, for testing.
    init(root: URL? = nil) {
        let root = root ?? ProcessInfo.processInfo.environment["DSCRATCH_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        UserDefaults.standard.register(defaults: [
            Prefs.autoLockMinutes: 5,
            Prefs.claudeModel: Prefs.defaultModel,
            Prefs.claudeIncludePage: true,
            Prefs.codeTheme: CodeTheme.automaticID,
            Prefs.claudeBackend: "claudeCode",
            Prefs.claudeCodeModel: "default",
            Prefs.claudeUseCaveman: false,
        ])
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? support.appendingPathComponent("D-Scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        MediaCache.clear()
        loadIndex()
        loadVault()
        if pages.isEmpty { createWelcomePage() }
        selection = pages.first?.id
        observeSystemEvents()
        startAutoLock()
    }

    // MARK: Lookup

    func page(_ id: UUID?) -> PageMeta? { pages.first { $0.id == id } }

    func isAccessible(_ page: PageMeta) -> Bool {
        !page.isLocked || (isUnlocked && !page.isLegacyLocked)
    }

    private func index(of id: UUID) -> Int? { pages.firstIndex { $0.id == id } }

    private func fileURL(_ page: PageMeta) -> URL {
        pagesDir.appendingPathComponent("\(page.id.uuidString).\(page.isLocked ? "locked" : "page")")
    }

    // MARK: Content

    /// Returns nil when a file exists but cannot be read, so callers never overwrite it.
    func loadContent(_ id: UUID) -> NSAttributedString? {
        guard let page = page(id) else { return nil }
        let url = fileURL(page)
        guard FileManager.default.fileExists(atPath: url.path) else { return NSAttributedString() }
        guard var data = try? Data(contentsOf: url) else { return nil }
        if page.isLocked {
            guard !page.isLegacyLocked, let key = dataKey, let plain = try? Vault.open(data, key: key) else { return nil }
            data = plain
        }
        return try? NSAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    }

    func saveContent(_ id: UUID, _ text: NSAttributedString) {
        guard let page = page(id) else { return }
        do {
            var data = try Self.rtfd(text)
            if page.isLocked {
                guard !page.isLegacyLocked, let key = dataKey else { return }
                data = try Vault.seal(data, key: key)
            }
            try data.write(to: fileURL(page), options: .atomic)
            textCache[id] = text.string
        } catch {
            NSLog("D-Scratch: save failed for \(id): \(error)")
        }
    }

    private static func rtfd(_ text: NSAttributedString) throws -> Data {
        try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    // MARK: Editor flushing

    func registerFlush(_ id: UUID, owner: AnyObject, _ flush: @escaping () -> Void) {
        flushers[id] = (ObjectIdentifier(owner), flush)
    }

    func unregisterFlush(_ id: UUID, owner: AnyObject) {
        if flushers[id]?.owner == ObjectIdentifier(owner) { flushers[id] = nil }
    }

    private func flush(_ id: UUID) { flushers[id]?.flush() }

    func flushAll() { flushers.values.forEach { $0.flush() } }

    // MARK: Page list

    func pages(in groupID: UUID?) -> [PageMeta] { pages.filter { $0.groupID == groupID } }

    func addPage(inGroup groupID: UUID? = nil) {
        let page = PageMeta(title: "Untitled", groupID: groupID)
        if let last = pages.lastIndex(where: { $0.groupID == groupID }) {
            pages.insert(page, at: last + 1)
        } else {
            pages.append(page)
        }
        saveIndex()
        if let groupID { setExpanded(groupID, true) }
        selection = page.id
        renamingID = page.id
    }

    /// Open With / dropped on the Dock icon: a new top-level page named after the file.
    func importFile(_ url: URL) {
        let page = PageMeta(title: url.deletingPathExtension().lastPathComponent)
        pages.append(page)
        saveIndex()
        saveContent(page.id, Self.importedContent(url))
        selection = page.id
    }

    static func importedContent(_ url: URL) -> NSAttributedString {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        func text() -> String? {
            var encoding = String.Encoding.utf8
            return (try? String(contentsOf: url, usedEncoding: &encoding)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        }
        func code(_ string: String) -> NSAttributedString {
            var trimmed = string
            while trimmed.hasSuffix("\n") { trimmed.removeLast() }
            return NSAttributedString(string: trimmed + "\n", attributes: CodeFormat.attributes())
        }

        if let kind = MediaAttachment.kind(forFilename: url.lastPathComponent),
           let wrapper = try? FileWrapper(url: url, options: .immediate) {
            wrapper.preferredFilename = url.lastPathComponent
            let result = NSMutableAttributedString(attachment: MediaAttachment(fileWrapper: wrapper, kind: kind))
            result.append(NSAttributedString(string: "\n", attributes: CodeFormat.bodyAttributes))
            return result
        }
        if [UTType.sourceCode, .script, .shellScript, .json, .xml, .yaml, .propertyList].contains(where: type.conforms(to:)),
           let string = text() {
            return code(string)
        }
        if let markdown = UTType("net.daringfireball.markdown"), type.conforms(to: markdown), let string = text() {
            return MarkdownRenderer.render(string)
        }
        if type.conforms(to: .plainText), let string = text() {
            return CodeFormat.looksLikeCode(string)
                ? code(string)
                : NSAttributedString(string: string, attributes: CodeFormat.bodyAttributes)
        }
        // RTF, RTFD, Word, HTML, OpenDocument…
        if let rich = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return rich
        }
        if let string = text() {
            return NSAttributedString(string: string, attributes: CodeFormat.bodyAttributes)
        }
        return NSAttributedString(string: "Couldn't read \(url.lastPathComponent).", attributes: CodeFormat.bodyAttributes)
    }

    /// New page in the same group as the selected page.
    func addPageNearSelection() {
        addPage(inGroup: page(selection)?.groupID)
    }

    /// Title of the page or group with this id.
    func name(of id: UUID?) -> String? {
        page(id)?.title ?? groups.first { $0.id == id }?.name
    }

    /// Renames a page or a group.
    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let i = index(of: id) {
            pages[i].title = trimmed
            saveIndex()
        } else if let g = groups.firstIndex(where: { $0.id == id }) {
            groups[g].name = trimmed
            saveGroups()
        }
    }

    /// Moves a page into `groupID` (nil = no group) at `position` among that group's pages (nil = end).
    /// `position` counts the page's current slot when it is already in the group, as a list drop does.
    func movePage(_ id: UUID, toGroup groupID: UUID?, at position: Int? = nil) {
        guard let from = index(of: id) else { return }
        if let groupID, !groups.contains(where: { $0.id == groupID }) { return }
        let before = pages(in: groupID).map(\.id)
        var target = min(max(position ?? before.count, 0), before.count)
        if let current = before.firstIndex(of: id), current < target { target -= 1 }

        var page = pages.remove(at: from)
        page.groupID = groupID
        let siblings = pages.indices.filter { pages[$0].groupID == groupID }
        let insertAt = target < siblings.count ? siblings[target] : (siblings.last.map { $0 + 1 } ?? pages.count)
        pages.insert(page, at: insertAt)
        saveIndex()
        if let groupID { setExpanded(groupID, true) }
    }

    // MARK: Groups

    func addGroup() {
        let group = PageGroup(name: "New Group")
        groups.append(group)
        saveGroups()
        renamingID = group.id
    }

    func setExpanded(_ groupID: UUID, _ expanded: Bool) {
        guard let g = groups.firstIndex(where: { $0.id == groupID }), groups[g].isExpanded != expanded else { return }
        groups[g].isExpanded = expanded
        saveGroups()
    }

    /// Deletes the group; its pages move out to the top level.
    func removeGroup(_ groupID: UUID) {
        for i in pages.indices where pages[i].groupID == groupID { pages[i].groupID = nil }
        groups.removeAll { $0.id == groupID }
        saveIndex()
        saveGroups()
    }

    func delete(_ id: UUID) {
        guard let i = index(of: id) else { return }
        try? FileManager.default.removeItem(at: fileURL(pages[i]))
        textCache[id] = nil
        pages.remove(at: i)
        saveIndex()
        if selection == id {
            selection = pages.indices.contains(i) ? pages[i].id : pages.last?.id
        }
    }

    // MARK: Master password

    func setMasterPassword(_ password: String) {
        guard vault == nil else { return }
        let key = SymmetricKey(size: .bits256)
        let salt = Vault.randomSalt()
        do {
            let wrapped = try Vault.seal(
                key.withUnsafeBytes { Data($0) }, key: Vault.deriveKey(password: password, salt: salt))
            try writeVault(VaultFile(salt: salt, wrappedKey: wrapped))
            dataKey = key
            isUnlocked = true
            lastActivity = Date()
        } catch {
            NSLog("D-Scratch: set password failed: \(error)")
        }
    }

    /// Returns false when `current` is wrong.
    func changeMasterPassword(current: String, new: String) -> Bool {
        guard let vault, let key = unwrap(vault, password: current) else { return false }
        let salt = Vault.randomSalt()
        do {
            let wrapped = try Vault.seal(
                key.withUnsafeBytes { Data($0) }, key: Vault.deriveKey(password: new, salt: salt))
            try writeVault(VaultFile(salt: salt, wrappedKey: wrapped))
            return true
        } catch {
            NSLog("D-Scratch: change password failed: \(error)")
            return false
        }
    }

    /// Unlocks every locked page. Returns false on a wrong password.
    func unlock(password: String) -> Bool {
        guard let vault, let key = unwrap(vault, password: password) else { return false }
        dataKey = key
        isUnlocked = true
        lastActivity = Date()
        return true
    }

    func lockAll() {
        guard isUnlocked else { return }
        flushAll()
        dataKey = nil
        isUnlocked = false
        for page in pages where page.isLocked { textCache[page.id] = nil }
        MediaCache.clear()
    }

    private func unwrap(_ vault: VaultFile, password: String) -> SymmetricKey? {
        let wrappingKey = Vault.deriveKey(password: password, salt: vault.salt)
        guard let raw = try? Vault.open(vault.wrappedKey, key: wrappingKey) else { return nil }
        return SymmetricKey(data: raw)
    }

    private func loadVault() {
        guard let data = try? Data(contentsOf: vaultURL),
              let file = try? JSONDecoder().decode(VaultFile.self, from: data) else { return }
        vault = file
        hasMasterPassword = true
    }

    private func writeVault(_ file: VaultFile) throws {
        try JSONEncoder().encode(file).write(to: vaultURL, options: .atomic)
        vault = file
        hasMasterPassword = true
    }

    // MARK: Page locking (needs the vault unlocked)

    /// Locks every listed page that isn't locked yet.
    func lockPages(_ ids: [UUID]) {
        ids.forEach(lockPage)
    }

    func lockPage(_ id: UUID) {
        guard let i = index(of: id), !pages[i].isLocked, let key = dataKey else { return }
        flush(id)
        let plainURL = fileURL(pages[i])
        do {
            let existing = try? Data(contentsOf: plainURL)
            let plain = try existing ?? Self.rtfd(NSAttributedString())
            let sealed = try Vault.seal(plain, key: key)
            pages[i].isLocked = true
            try sealed.write(to: fileURL(pages[i]), options: .atomic)
            try? FileManager.default.removeItem(at: plainURL)
            saveIndex()
        } catch {
            pages[i].isLocked = false
            NSLog("D-Scratch: lock failed for \(id): \(error)")
        }
    }

    /// Decrypts an unlocked page permanently.
    func removeLock(_ id: UUID) {
        guard let i = index(of: id), pages[i].isLocked, !pages[i].isLegacyLocked, let key = dataKey else { return }
        flush(id)
        let lockedURL = fileURL(pages[i])
        do {
            let plain = try Vault.open(try Data(contentsOf: lockedURL), key: key)
            pages[i].isLocked = false
            try plain.write(to: fileURL(pages[i]), options: .atomic)
            try? FileManager.default.removeItem(at: lockedURL)
            saveIndex()
        } catch {
            pages[i].isLocked = true
            NSLog("D-Scratch: remove lock failed for \(id): \(error)")
        }
    }

    /// Re-encrypts a v0.1 page (own password) under the master password. Returns false on a wrong password.
    func migrateLegacyPage(_ id: UUID, oldPassword: String) -> Bool {
        guard let i = index(of: id), pages[i].isLegacyLocked, let salt = pages[i].salt, let key = dataKey,
              let sealed = try? Data(contentsOf: fileURL(pages[i])),
              let plain = try? Vault.open(sealed, key: Vault.deriveKey(password: oldPassword, salt: salt)),
              let resealed = try? Vault.seal(plain, key: key),
              (try? resealed.write(to: fileURL(pages[i]), options: .atomic)) != nil
        else { return false }
        pages[i].salt = nil
        saveIndex()
        return true
    }

    // MARK: Auto-lock

    func noteActivity() { lastActivity = Date() }

    private func startAutoLock() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.noteActivity() }
            return event
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAutoLock() }
        }
    }

    private func checkAutoLock() {
        let minutes = UserDefaults.standard.integer(forKey: Prefs.autoLockMinutes)
        guard isUnlocked, minutes > 0, Date().timeIntervalSince(lastActivity) >= Double(minutes) * 60 else { return }
        lockAll()
    }

    // MARK: Search

    /// Case- and diacritic-insensitive search over titles and text of every page that is currently readable.
    func search(_ query: String) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        flushAll()
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var hits: [SearchHit] = []
        for page in pages where isAccessible(page) {
            if page.title.range(of: needle, options: options) != nil {
                hits.append(SearchHit(pageID: page.id, snippet: AttributedString("Title match"), range: nil))
            }
            guard let text = plainText(page.id) else { continue }
            let ns = text as NSString
            var scope = NSRange(location: 0, length: ns.length)
            for _ in 0..<20 {
                let found = ns.range(of: needle, options: options, range: scope)
                if found.location == NSNotFound { break }
                hits.append(SearchHit(pageID: page.id, snippet: Self.snippet(ns, found), range: found))
                let next = NSMaxRange(found)
                scope = NSRange(location: next, length: ns.length - next)
            }
        }
        return hits
    }

    func reveal(_ hit: SearchHit) {
        if let groupID = page(hit.pageID)?.groupID { setExpanded(groupID, true) }
        selection = hit.pageID
        if let range = hit.range { pendingReveal = Reveal(pageID: hit.pageID, range: range) }
    }

    private func plainText(_ id: UUID) -> String? {
        if let cached = textCache[id] { return cached }
        guard let text = loadContent(id)?.string else { return nil }
        textCache[id] = text
        return text
    }

    private static func snippet(_ ns: NSString, _ match: NSRange) -> AttributedString {
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{FFFC}", with: "").components(separatedBy: .newlines).joined(separator: " ")
        }
        let start = max(0, match.location - 40)
        let end = min(ns.length, NSMaxRange(match) + 60)
        var result = AttributedString(
            (start > 0 ? "…" : "") + clean(ns.substring(with: NSRange(location: start, length: match.location - start))))
        var hit = AttributedString(clean(ns.substring(with: match)))
        hit.font = .body.bold()
        result.append(hit)
        result.append(AttributedString(
            clean(ns.substring(with: NSRange(location: NSMaxRange(match), length: end - NSMaxRange(match))))
                + (end < ns.length ? "…" : "")))
        return result
    }

    // MARK: Persistence

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([PageMeta].self, from: data) else { return }
        pages = list
        if let data = try? Data(contentsOf: groupsURL),
           let saved = try? JSONDecoder().decode([PageGroup].self, from: data) {
            groups = saved
        }
        // Pages pointing at a missing group fall back to the top level.
        let known = Set(groups.map(\.id))
        for i in pages.indices where pages[i].groupID.map({ !known.contains($0) }) ?? false {
            pages[i].groupID = nil
        }
    }

    private func saveGroups() {
        do {
            try JSONEncoder().encode(groups).write(to: groupsURL, options: .atomic)
        } catch {
            NSLog("D-Scratch: groups save failed: \(error)")
        }
    }

    private func saveIndex() {
        do {
            try JSONEncoder().encode(pages).write(to: indexURL, options: .atomic)
        } catch {
            NSLog("D-Scratch: index save failed: \(error)")
        }
    }

    private func createWelcomePage() {
        let page = PageMeta(title: "Welcome")
        pages = [page]
        saveIndex()
        let body = NSFont.systemFont(ofSize: 14)
        let text = NSMutableAttributedString(
            string: "Welcome to D-Scratch\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.textColor])
        text.append(NSAttributedString(
            string: """
            • ⌘N adds a page. Right-click a page to rename, lock or delete it.
            • ⌘B / ⌘I / ⌘U for bold, italic, underline. ⌘T opens the font panel.
            • Use the format bar above the text for fonts, colours, alignment and lists.
            • Drag, paste or ⇧⌘I to insert images, video and audio.
            • Set your password in Settings (⌘,). One password unlocks every locked page; ⌘L locks them all.
            • Search every page from the sidebar search field.
            • Add a Claude API key in Settings, then ask Claude from the bar at the top of any page.

            """,
            attributes: [.font: body, .foregroundColor: NSColor.textColor]))
        saveContent(page.id, text)
    }

    private func observeSystemEvents() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushAll()
                MediaCache.clear()
            }
        }
        let lockEvents: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
        ]
        for (center, name) in lockEvents {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockAll() }
            }
        }
    }
}
