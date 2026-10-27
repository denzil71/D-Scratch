import AppKit

/// Checks GitHub for a newer release and offers a link to it. Nothing is downloaded or installed.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/denzil71/D-Scratch/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/denzil71/D-Scratch/releases")!
    /// Automatic checks run at most this often.
    private static let interval: TimeInterval = 24 * 60 * 60

    @Published private(set) var isChecking = false
    /// What the last check found, for Settings.
    @Published private(set) var status: String?

    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks shortly after launch, then whenever a day has passed since the last check (while enabled).
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Prefs.checkForUpdates) else { return }
        let last = defaults.object(forKey: Prefs.lastUpdateCheck) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.interval else { return }
        Task { await check(userInitiated: false) }
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// `userInitiated` checks also report "up to date" and errors, and ignore a skipped version.
    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        var request = URLRequest(url: Self.latestReleaseAPI, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let release: Release
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            status = "Couldn't check for updates."
            NSLog("D-Scratch: update check failed: \(error)")
            if userInitiated {
                show(title: "Couldn't Check for Updates",
                     message: "D-Scratch couldn't reach GitHub. Check your internet connection and try again.")
            }
            return
        }
        UserDefaults.standard.set(Date(), forKey: Prefs.lastUpdateCheck)

        let latest = Self.version(fromTag: release.tagName)
        let current = Self.currentVersion
        guard Self.isNewer(latest, than: current) else {
            status = "D-Scratch \(current) is the latest version."
            if userInitiated {
                show(title: "You're Up to Date", message: "D-Scratch \(current) is the latest version.")
            }
            return
        }
        status = "D-Scratch \(latest) is available."
        if !userInitiated, UserDefaults.standard.string(forKey: Prefs.skippedUpdateVersion) == latest { return }
        offer(latest, current: current, page: release.htmlURL)
    }

    private func offer(_ version: String, current: String, page: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "D-Scratch \(version) Is Available"
        alert.informativeText = "You have \(current). The release page has what's new and the download."
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(page)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(version, forKey: Prefs.skippedUpdateVersion)
        default:
            break
        }
    }

    private func show(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// "v0.7.1" → "0.7.1".
    static func version(fromTag tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Numeric, part by part: 0.10.0 is newer than 0.9.3, and 0.7 equals 0.7.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
