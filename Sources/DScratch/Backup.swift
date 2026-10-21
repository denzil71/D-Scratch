import AppKit
import CryptoKit

/// Unencrypted header at the start of a backup file: everything needed to decrypt it with the
/// D-Scratch password that was set when it was made — nothing that reveals the contents.
struct BackupHeader: Codable {
    struct Keys: Codable {
        var salt: Data
        var wrappedDataKey: Data
        var publicKey: Data
        var wrappedPrivateKey: Data
    }

    var version = 1
    var created: Date
    var keys: Keys
    var ephemeralPublicKey: Data

    static let magic = Data("DSCRATCH-BACKUP\n".utf8)
    static let fileExtension = "dscratch-backup"

    /// X25519 with a fresh ephemeral key, HKDF-SHA256, then AES-256-GCM. Needs no password.
    static func encrypt(_ plain: Data, keys: Keys) throws -> Data {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keys.publicKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let key = try sharedKey(ephemeral.publicKey.rawRepresentation, recipient.rawRepresentation,
                                ephemeral.sharedSecretFromKeyAgreement(with: recipient))
        let header = BackupHeader(created: Date(), keys: keys, ephemeralPublicKey: ephemeral.publicKey.rawRepresentation)
        let headerData = try JSONEncoder().encode(header)
        var out = magic
        withUnsafeBytes(of: UInt32(headerData.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(headerData)
        out.append(try Vault.seal(plain, key: key))
        return out
    }

    /// Throws `wrongPassword` if the password doesn't open this backup's keys.
    static func decrypt(_ file: Data, password: String) throws -> Data {
        guard file.starts(with: magic), file.count > magic.count + 4 else { throw BackupController.Failure.notABackup }
        let lengthStart = file.startIndex + magic.count
        let length = file[lengthStart..<lengthStart + 4].reduce(0) { $0 << 8 | Int($1) }
        let headerStart = lengthStart + 4
        guard file.count >= magic.count + 4 + length,
              let header = try? JSONDecoder().decode(BackupHeader.self, from: file[headerStart..<headerStart + length])
        else { throw BackupController.Failure.notABackup }
        let passwordKey = Vault.deriveKey(password: password, salt: header.keys.salt)
        guard let rawDataKey = try? Vault.open(header.keys.wrappedDataKey, key: passwordKey) else {
            throw BackupController.Failure.wrongPassword
        }
        let rawPrivate = try Vault.open(header.keys.wrappedPrivateKey, key: SymmetricKey(data: rawDataKey))
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivate)
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: header.ephemeralPublicKey)
        let key = try sharedKey(header.ephemeralPublicKey, header.keys.publicKey,
                                privateKey.sharedSecretFromKeyAgreement(with: ephemeral))
        return try Vault.open(Data(file[(headerStart + length)...]), key: key)
    }

    private static func sharedKey(_ ephemeral: Data, _ recipient: Data, _ secret: SharedSecret) throws -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: ephemeral + recipient, sharedInfo: Data("D-Scratch backup v1".utf8),
            outputByteCount: 32)
    }
}

/// Encrypted backups of the data folder in iCloud Drive › D-Scratch Backups.
/// iCloud Drive is a plain folder that macOS syncs, so this works without iCloud entitlements
/// (which need a paid Developer ID). Each backup is a zip of the data folder, encrypted with
/// `BackupHeader.encrypt` before it is written, so nothing readable reaches iCloud.
@MainActor
final class BackupController: ObservableObject {
    enum Frequency: String, CaseIterable, Identifiable {
        case hourly, daily, weekly
        var id: String { rawValue }
        var interval: TimeInterval {
            switch self {
            case .hourly: return 3600
            case .daily: return 86_400
            case .weekly: return 7 * 86_400
            }
        }
        var label: String {
            switch self {
            case .hourly: return "Every hour"
            case .daily: return "Every day"
            case .weekly: return "Every week"
            }
        }
    }

    enum Failure: LocalizedError {
        case noICloudDrive
        case noPassword
        case needsUnlock
        case notABackup
        case wrongPassword
        case zip(String)

        var errorDescription: String? {
            switch self {
            case .noICloudDrive:
                return "iCloud Drive isn't available. Turn it on in System Settings › Apple Account › iCloud › iCloud Drive."
            case .noPassword:
                return "Set a D-Scratch password in Settings › Security first. Backups are encrypted with it."
            case .needsUnlock:
                return "Unlock your locked pages once to finish setting up encrypted backups."
            case .notABackup: return "That file isn't a D-Scratch backup."
            case .wrongPassword:
                return "Wrong password. Use the D-Scratch password that was set when this backup was made."
            case .zip(let message): return "Couldn't create or open the backup: \(message)"
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastBackup: Date?

    private weak var store: Store?
    private var timer: Timer?
    private static let prefix = "D-Scratch Backup "

    init(store: Store) {
        self.store = store
        let stamp = UserDefaults.standard.double(forKey: Prefs.lastBackup)
        lastBackup = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    // MARK: Location

    static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// iCloud Drive › D-Scratch Backups (DSCRATCH_BACKUP_DIR overrides it, for testing).
    static var folder: URL? {
        if let override = ProcessInfo.processInfo.environment["DSCRATCH_BACKUP_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return iCloudDrive?.appendingPathComponent("D-Scratch Backups", isDirectory: true)
    }

    /// Backups in the folder, newest first.
    static func backups() -> [URL] {
        guard let folder,
              let items = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return items
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == BackupHeader.fileExtension }
            .sorted { modified($0) > modified($1) }
    }

    // MARK: Schedule

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.backupEnabled) }

    private var frequency: Frequency {
        Frequency(rawValue: UserDefaults.standard.string(forKey: Prefs.backupFrequency) ?? "") ?? .daily
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.backUpIfDue() }
        }
        // Shortly after launch, catch up on a backup that came due while the app was closed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.backUpIfDue() }
    }

    /// Backs up when enabled, the interval has passed, and something changed since the last backup.
    func backUpIfDue(now: Date = Date()) {
        guard isEnabled, !isRunning, let store else { return }
        if let lastBackup {
            guard now.timeIntervalSince(lastBackup) >= frequency.interval, store.latestChange() > lastBackup else { return }
        }
        Task { await backUpNow() }
    }

    // MARK: Back up

    /// Zips and encrypts the data folder into the backup folder, then prunes old backups.
    @discardableResult
    func backUpNow() async -> URL? {
        guard let store, !isRunning else { return nil }
        guard let folder = Self.folder else {
            lastError = Failure.noICloudDrive.localizedDescription
            return nil
        }
        guard let keys = store.backupKeyMaterial else {
            lastError = (store.backupKeyState == .noPassword ? Failure.noPassword : Failure.needsUnlock).localizedDescription
            return nil
        }
        isRunning = true
        defer { isRunning = false }
        store.flushAll()

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("D-Scratch-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let stem = Self.prefix + formatter.string(from: Date())
        var destination = folder.appendingPathComponent(stem + "." + BackupHeader.fileExtension)
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(stem) \(n).\(BackupHeader.fileExtension)")
            n += 1
        }
        do {
            // Snapshot first (quick, on the main actor) so saves can't change files mid-zip.
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let snapshot = work.appendingPathComponent("D-Scratch", isDirectory: true)
            try fm.copyItem(at: store.dataFolder, to: snapshot)
            let zip = work.appendingPathComponent("backup.zip")
            try await Self.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", snapshot.path, zip.path])
            // Encrypt locally; only ciphertext is written into iCloud Drive.
            let encrypted = try BackupHeader.encrypt(try Data(contentsOf: zip), keys: keys)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try encrypted.write(to: destination, options: .atomic)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        lastError = nil
        lastBackup = Date()
        UserDefaults.standard.set(lastBackup!.timeIntervalSince1970, forKey: Prefs.lastBackup)
        prune()
        return destination
    }

    /// Keeps the newest N backups.
    private func prune() {
        let keep = max(1, UserDefaults.standard.integer(forKey: Prefs.backupKeep))
        for old in Self.backups().dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }

    // MARK: Restore

    /// Decrypts a backup with the D-Scratch password it was made under and replaces the current
    /// data with it. The current data folder is kept beside it as "D-Scratch before restore …".
    /// Returns that copy's location.
    @discardableResult
    func restore(from backup: URL, password: String) async throws -> URL {
        guard let store else { throw Failure.notABackup }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("D-Scratch-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let fileData = try Data(contentsOf: backup)
        let zipData = try await Task.detached { try BackupHeader.decrypt(fileData, password: password) }.value
        let zip = work.appendingPathComponent("backup.zip")
        try zipData.write(to: zip)
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let restored = work.appendingPathComponent("D-Scratch", isDirectory: true)
        guard fm.fileExists(atPath: restored.appendingPathComponent("index.json").path) else { throw Failure.notABackup }
        return try store.replaceData(with: restored)
    }

    func showInFinder() {
        guard let folder = Self.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Self.backups().first ?? folder])
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw Failure.zip(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }
}
