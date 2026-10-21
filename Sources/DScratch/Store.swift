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
    /// Tags applied to this page directly (optional so older index files still decode).
    var tagIDs: [UUID]?

    var isLegacyLocked: Bool { isLocked && salt != nil }
}

struct PageGroup: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var isExpanded = true
    /// Tags applied to the group; every page in it inherits them.
    var tagIDs: [UUID]?
}

struct Tag: Codable, Identifiable, Hashable {
    var id = UUID()
    /// One word: spaces become hyphens, so it can be searched as #name.
    var name: String
    /// sRGB hex, e.g. "#4F8EF7".
    var color: String

    /// A random, fairly saturated colour that reads well with white or black text.
    static func randomColor() -> String {
        let color = NSColor(
            hue: .random(in: 0..<1), saturation: .random(in: 0.45...0.7), brightness: .random(in: 0.75...0.92), alpha: 1)
        return color.hexString
    }
}

extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// The master password wraps a random data key; locked pages are encrypted with the data key,
/// so changing the password only re-wraps the key.
struct VaultFile: Codable {
    var salt: Data
    var wrappedKey: Data
    /// Curve25519 key pair for encrypting backups: the public key encrypts without a password;
    /// the private key is sealed with the data key (so only the password can open backups).
    var backupPublicKey: Data?
    var wrappedBackupKey: Data?
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
    static let backupEnabled = "backupEnabled"
    static let backupFrequency = "backupFrequency"
    static let backupKeep = "backupKeep"
    static let lastBackup = "lastBackup"
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
    @Published var tags: [Tag] = []
    /// The sidebar search text; `#name` words filter by tag.
    @Published var searchQuery = ""
    @Published var pendingReveal: Reveal?
    @Published private(set) var hasMasterPassword = false
    @Published private(set) var isUnlocked = false
    /// Bumped when the whole data folder is replaced (restore); editors opened before it can't save.
    @Published private(set) var dataGeneration = 0

    /// Automatic and manual backups to iCloud Drive.
    lazy var backup = BackupController(store: self)

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
    private var tagsURL: URL { root.appendingPathComponent("tags.json") }
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
            Prefs.backupEnabled: false,
            Prefs.backupFrequency: BackupController.Frequency.daily.rawValue,
            Prefs.backupKeep: 10,
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
        backup.start()
    }

    /// The folder holding all of D-Scratch's data.
    var dataFolder: URL { root }

    /// Newest modification time of anything in the data folder.
    func latestChange() -> Date {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)?
            .compactMap { $0 as? URL } ?? []
        return files.compactMap { try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate }.max() ?? .distantPast
    }

    /// Replaces all data with the contents of `folder` (a restored backup) and reloads.
    /// The previous data folder is kept beside it; returns that copy's location.
    @discardableResult
    func replaceData(with folder: URL) throws -> URL {
        lockAll()
        flushAll()
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let base = "D-Scratch before restore \(formatter.string(from: Date()))"
        var previous = root.deletingLastPathComponent().appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: previous.path) {
            previous = root.deletingLastPathComponent().appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        try fm.copyItem(at: root, to: previous)
        let staging = root.deletingLastPathComponent().appendingPathComponent("D-Scratch-restoring-\(UUID().uuidString)")
        try fm.copyItem(at: folder, to: staging)
        _ = try fm.replaceItemAt(root, withItemAt: staging)
        try? fm.createDirectory(at: pagesDir, withIntermediateDirectories: true)

        dataGeneration += 1
        flushers.removeAll()
        textCache.removeAll()
        vault = nil
        dataKey = nil
        isUnlocked = false
        hasMasterPassword = false
        pages = []
        groups = []
        tags = []
        searchQuery = ""
        MediaCache.clear()
        loadIndex()
        loadVault()
        if pages.isEmpty { createWelcomePage() }
        selection = pages.first?.id
        return previous
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

    /// `generation` is the `dataGeneration` the caller loaded from; stale callers are ignored.
    func saveContent(_ id: UUID, _ text: NSAttributedString, generation: Int? = nil) {
        if let generation, generation != dataGeneration { return }
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

    /// New page in the selected group, or alongside the selected page.
    func addPageNearSelection() {
        addPage(inGroup: selectionGroupID)
    }

    /// The selected group, or the group of the selected page; nil at the top level.
    var selectionGroupID: UUID? {
        if let group = groups.first(where: { $0.id == selection }) { return group.id }
        return page(selection)?.groupID
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
    /// Deletes the group and every page in it.
    func deleteGroupAndPages(_ groupID: UUID) {
        for page in pages(in: groupID) { delete(page.id) }
        removeGroup(groupID)
    }

    func removeGroup(_ groupID: UUID) {
        for i in pages.indices where pages[i].groupID == groupID { pages[i].groupID = nil }
        groups.removeAll { $0.id == groupID }
        saveIndex()
        saveGroups()
        if selection == groupID { selection = nil }
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
            ensureBackupKeys()
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
            var updated = vault
            updated.salt = salt
            updated.wrappedKey = wrapped
            try writeVault(updated)
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
        ensureBackupKeys()
        return true
    }

    // MARK: Backup encryption

    /// Creates the backup key pair the first time the vault is unlocked (needs the data key).
    private func ensureBackupKeys() {
        guard var file = vault, file.backupPublicKey == nil, let dataKey else { return }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        do {
            file.backupPublicKey = privateKey.publicKey.rawRepresentation
            file.wrappedBackupKey = try Vault.seal(privateKey.rawRepresentation, key: dataKey)
            try writeVault(file)
        } catch {
            NSLog("D-Scratch: backup key setup failed: \(error)")
        }
    }

    enum BackupKeyState { case noPassword, needsUnlock, ready }

    var backupKeyState: BackupKeyState {
        guard let vault else { return .noPassword }
        return vault.backupPublicKey == nil ? .needsUnlock : .ready
    }

    /// What a backup file must carry so the D-Scratch password alone can decrypt it later.
    var backupKeyMaterial: BackupHeader.Keys? {
        guard let vault, let publicKey = vault.backupPublicKey, let wrapped = vault.wrappedBackupKey else { return nil }
        return BackupHeader.Keys(salt: vault.salt, wrappedDataKey: vault.wrappedKey, publicKey: publicKey, wrappedPrivateKey: wrapped)
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
    /// Searches every readable page. Words starting with `#` filter by tag (prefix match on any of the
    /// page's own or group tags, all must match); the remaining words are searched case- and
    /// diacritic-insensitively in titles and text. With only tags, every matching page is listed.
    func search(_ query: String) -> [SearchHit] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let tagFilters = words.filter { $0.hasPrefix("#") && $0.count > 1 }.map { $0.dropFirst().lowercased() }
        let needle = words.filter { !$0.hasPrefix("#") }.joined(separator: " ")
        guard !needle.isEmpty || !tagFilters.isEmpty else { return [] }
        flushAll()
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var hits: [SearchHit] = []
        for page in pages where isAccessible(page) {
            let names = effectiveTags(of: page).map { $0.name.lowercased() }
            guard tagFilters.allSatisfy({ filter in names.contains { $0.hasPrefix(filter) } }) else { continue }
            if needle.isEmpty {
                let label = effectiveTags(of: page).map { "#\($0.name)" }.joined(separator: " ")
                hits.append(SearchHit(pageID: page.id, snippet: AttributedString(label), range: nil))
                continue
            }
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

    /// Adds `#name` to the search, or removes it if it's already there.
    func toggleTagFilter(_ tag: Tag) {
        let token = "#\(tag.name)"
        var words = searchQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        if let i = words.firstIndex(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) {
            words.remove(at: i)
        } else {
            words.append(token)
        }
        searchQuery = words.joined(separator: " ")
    }

    // MARK: Tags

    func tag(_ id: UUID) -> Tag? { tags.first { $0.id == id } }

    /// Tags on the page itself, then tags inherited from its group (not repeated).
    func pageTags(_ page: PageMeta) -> [Tag] { (page.tagIDs ?? []).compactMap(tag) }

    func groupTags(_ groupID: UUID?) -> [Tag] {
        (groups.first { $0.id == groupID }?.tagIDs ?? []).compactMap(tag)
    }

    func inheritedTags(of page: PageMeta) -> [Tag] {
        let own = Set(page.tagIDs ?? [])
        return groupTags(page.groupID).filter { !own.contains($0.id) }
    }

    func effectiveTags(of page: PageMeta) -> [Tag] { pageTags(page) + inheritedTags(of: page) }

    /// Tag names are one word without a leading #.
    static func normalizedTagName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: "-")
    }

    /// Returns the existing tag with this name (any case), or creates one with a random colour.
    @discardableResult
    func createTag(named name: String) -> Tag? {
        let clean = Self.normalizedTagName(name)
        guard !clean.isEmpty else { return nil }
        if let existing = tags.first(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) { return existing }
        let tag = Tag(name: clean, color: Tag.randomColor())
        tags.append(tag)
        saveTags()
        return tag
    }

    func renameTag(_ id: UUID, to name: String) {
        let clean = Self.normalizedTagName(name)
        guard !clean.isEmpty, let i = tags.firstIndex(where: { $0.id == id }),
              !tags.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(clean) == .orderedSame })
        else { return }
        tags[i].name = clean
        saveTags()
    }

    func setTagColor(_ id: UUID, _ color: String) {
        guard let i = tags.firstIndex(where: { $0.id == id }), tags[i].color != color else { return }
        tags[i].color = color
        saveTags()
    }

    /// Deletes the tag and removes it from every page and group.
    func deleteTag(_ id: UUID) {
        tags.removeAll { $0.id == id }
        for i in pages.indices { pages[i].tagIDs?.removeAll { $0 == id } }
        for i in groups.indices { groups[i].tagIDs?.removeAll { $0 == id } }
        saveTags()
        saveIndex()
        saveGroups()
    }

    /// Pages and groups using the tag directly.
    func usageCount(of id: UUID) -> Int {
        pages.filter { $0.tagIDs?.contains(id) == true }.count + groups.filter { $0.tagIDs?.contains(id) == true }.count
    }

    func addTag(_ tagID: UUID, toPage pageID: UUID) {
        guard let i = index(of: pageID), !(pages[i].tagIDs ?? []).contains(tagID) else { return }
        pages[i].tagIDs = (pages[i].tagIDs ?? []) + [tagID]
        saveIndex()
    }

    func removeTag(_ tagID: UUID, fromPage pageID: UUID) {
        guard let i = index(of: pageID) else { return }
        pages[i].tagIDs?.removeAll { $0 == tagID }
        saveIndex()
    }

    func addTag(_ tagID: UUID, toGroup groupID: UUID) {
        guard let g = groups.firstIndex(where: { $0.id == groupID }), !(groups[g].tagIDs ?? []).contains(tagID) else { return }
        groups[g].tagIDs = (groups[g].tagIDs ?? []) + [tagID]
        saveGroups()
    }

    func removeTag(_ tagID: UUID, fromGroup groupID: UUID) {
        guard let g = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[g].tagIDs?.removeAll { $0 == tagID }
        saveGroups()
    }

    private func saveTags() {
        do {
            try JSONEncoder().encode(tags).write(to: tagsURL, options: .atomic)
        } catch {
            NSLog("D-Scratch: tags save failed: \(error)")
        }
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
        if let data = try? Data(contentsOf: tagsURL),
           let saved = try? JSONDecoder().decode([Tag].self, from: data) {
            tags = saved
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
