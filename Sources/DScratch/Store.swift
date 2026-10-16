import AppKit
import CryptoKit
import SwiftUI

struct PageMeta: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var isLocked = false
    var salt: Data?
}

/// Owns the page list and all reads/writes to disk.
/// Layout: ~/Library/Application Support/D-Scratch/{index.json, pages/<id>.page | <id>.locked}
@MainActor
final class Store: ObservableObject {
    @Published var pages: [PageMeta] = []
    @Published var selection: UUID?
    @Published var renamingID: UUID?
    @Published private(set) var unlocked: Set<UUID> = []

    /// Text view of the page currently on screen.
    weak var activeTextView: DTextView?

    private var keys: [UUID: SymmetricKey] = [:]
    private var flushers: [UUID: (owner: ObjectIdentifier, flush: () -> Void)] = [:]
    private let root: URL
    private var pagesDir: URL { root.appendingPathComponent("pages", isDirectory: true) }
    private var indexURL: URL { root.appendingPathComponent("index.json") }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("D-Scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        MediaCache.clear()
        loadIndex()
        if pages.isEmpty { createWelcomePage() }
        selection = pages.first?.id
        observeSystemEvents()
    }

    // MARK: Lookup

    func page(_ id: UUID?) -> PageMeta? { pages.first { $0.id == id } }

    func isAccessible(_ page: PageMeta) -> Bool { !page.isLocked || unlocked.contains(page.id) }

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
            guard let key = keys[id], let plain = try? Vault.open(data, key: key) else { return nil }
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
                guard let key = keys[id] else { return }
                data = try Vault.seal(data, key: key)
            }
            try data.write(to: fileURL(page), options: .atomic)
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

    func addPage() {
        let page = PageMeta(title: "Untitled")
        pages.append(page)
        saveIndex()
        selection = page.id
        renamingID = page.id
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = index(of: id), !trimmed.isEmpty else { return }
        pages[i].title = trimmed
        saveIndex()
    }

    func move(from source: IndexSet, to destination: Int) {
        pages.move(fromOffsets: source, toOffset: destination)
        saveIndex()
    }

    func delete(_ id: UUID) {
        guard let i = index(of: id) else { return }
        try? FileManager.default.removeItem(at: fileURL(pages[i]))
        keys[id] = nil
        unlocked.remove(id)
        pages.remove(at: i)
        saveIndex()
        if selection == id {
            selection = pages.indices.contains(i) ? pages[i].id : pages.last?.id
        }
    }

    // MARK: Locking

    func lock(_ id: UUID, password: String) {
        guard let i = index(of: id), !pages[i].isLocked else { return }
        flush(id)
        let plainURL = fileURL(pages[i])
        do {
            let existing = try? Data(contentsOf: plainURL)
            let plain = try existing ?? Self.rtfd(NSAttributedString())
            let salt = Vault.randomSalt()
            let sealed = try Vault.seal(plain, key: Vault.deriveKey(password: password, salt: salt))
            pages[i].isLocked = true
            pages[i].salt = salt
            try sealed.write(to: fileURL(pages[i]), options: .atomic)
            try? FileManager.default.removeItem(at: plainURL)
            saveIndex()
        } catch {
            pages[i].isLocked = false
            pages[i].salt = nil
            NSLog("D-Scratch: lock failed for \(id): \(error)")
        }
        keys[id] = nil
        unlocked.remove(id)
        MediaCache.clear()
    }

    /// Returns false on a wrong password.
    func unlock(_ id: UUID, password: String) -> Bool {
        guard let page = page(id), page.isLocked, let salt = page.salt,
              let sealed = try? Data(contentsOf: fileURL(page)) else { return false }
        let key = Vault.deriveKey(password: password, salt: salt)
        guard (try? Vault.open(sealed, key: key)) != nil else { return false }
        keys[id] = key
        unlocked.insert(id)
        return true
    }

    func relock(_ id: UUID) {
        flush(id)
        keys[id] = nil
        unlocked.remove(id)
        MediaCache.clear()
    }

    func lockAll() {
        for id in Array(unlocked) { relock(id) }
    }

    /// Decrypts an unlocked page permanently.
    func removeLock(_ id: UUID) {
        guard let i = index(of: id), pages[i].isLocked, let key = keys[id] else { return }
        flush(id)
        let lockedURL = fileURL(pages[i])
        do {
            let plain = try Vault.open(try Data(contentsOf: lockedURL), key: key)
            pages[i].isLocked = false
            pages[i].salt = nil
            try plain.write(to: fileURL(pages[i]), options: .atomic)
            try? FileManager.default.removeItem(at: lockedURL)
            saveIndex()
            keys[id] = nil
            unlocked.remove(id)
        } catch {
            pages[i].isLocked = true
            pages[i].salt = page(id)?.salt
            NSLog("D-Scratch: remove lock failed for \(id): \(error)")
        }
    }

    // MARK: Persistence

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([PageMeta].self, from: data) else { return }
        pages = list
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
            • Locked pages are encrypted on disk. ⌘L locks every page at once.

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
