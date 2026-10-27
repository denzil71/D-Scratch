import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            SecuritySettings().tabItem { Label("Security", systemImage: "lock") }
            TagSettings().tabItem { Label("Tags", systemImage: "tag") }
            BackupSettings().tabItem { Label("Backup", systemImage: "icloud") }
            CaptureSettings().tabItem { Label("Capture", systemImage: "square.and.pencil") }
            CodeSettings().tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            ClaudeSettings().tabItem { Label("Claude", systemImage: "sparkles") }
        }
        .frame(width: 480, height: 420)
    }
}

struct CaptureSettings: View {
    @AppStorage(Prefs.captureShortcut) private var shortcutID = CaptureShortcut.defaultID
    @ObservedObject private var hotKey = GlobalHotKey.shared

    var body: some View {
        Form {
            Section("Quick Capture") {
                Picker("Shortcut", selection: $shortcutID) {
                    Text("Off").tag(CaptureShortcut.offID)
                    ForEach(CaptureShortcut.all) { Text($0.label).tag($0.id) }
                }
                if hotKey.failed {
                    Text("That shortcut is already used by another app. Pick a different one.")
                        .font(.callout).foregroundStyle(.red)
                }
                Text("Press the shortcut in any app to jot a note into a new page without leaving what you're doing. Return saves, Shift-Return starts a new line, Esc cancels. The panel remembers where you last saved (the Inbox group to start with). While a shortcut is set, D-Scratch keeps running after you close its window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("From Other Apps") {
                Text("Select text in any app, then choose **New D-Scratch Page from Selection** from the app's menu › Services, or right-click › Services. The text opens in Quick Capture so you can title it and pick a group before saving.")
                    .font(.callout)
                HStack {
                    Text("Give it a shortcut in System Settings › Keyboard › Keyboard Shortcuts › Services › Text.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: shortcutID) { _ in hotKey.apply() }
    }
}

struct CodeSettings: View {
    @AppStorage(Prefs.codeTheme) private var themeID = CodeTheme.automaticID
    @Environment(\.colorScheme) private var colorScheme

    static let sample = """
        // Fetch a greeting
        func greet(_ name: String) -> String {
            let count = 42
            return "Hello, \\(name)! #\\(count)"
        }
        """

    var body: some View {
        Form {
            Section("Code Highlighting") {
                Picker("Colour scheme", selection: $themeID) {
                    Text("Automatic (Light / Dark)").tag(CodeTheme.automaticID)
                    ForEach(CodeTheme.all) { Text($0.name).tag($0.id) }
                }
                CodePreview(theme: CodeTheme.resolve(
                    themeID, appearance: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)))
                    .frame(height: 120)
                Text("Pasted code is detected and placed in a highlighted box. You can also type ``` and press Return, or select text and choose Format › Code Block (⌥⌘K). Press Return on an empty last line to leave a block.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: themeID) { _ in
            NotificationCenter.default.post(name: CodeTheme.changedNotification, object: nil)
        }
    }
}

struct CodePreview: NSViewRepresentable {
    let theme: CodeTheme

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = false
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        view.backgroundColor = theme.background
        let text = NSMutableAttributedString(attributedString: CodeFormat.highlighted(CodeSettings.sample, theme: theme))
        text.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: text.length))
        view.textStorage?.setAttributedString(text)
    }
}

struct SecuritySettings: View {
    @EnvironmentObject var store: Store
    @AppStorage(Prefs.autoLockMinutes) private var minutes = 5
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        Form {
            Section(store.hasMasterPassword ? "Change Password" : "Set Password") {
                if store.hasMasterPassword {
                    SecureField("Current password", text: $current)
                }
                SecureField("New password", text: $new)
                SecureField("Confirm new password", text: $confirm)
                HStack {
                    if let message {
                        Text(message).font(.callout).foregroundStyle(isError ? .red : .green)
                    } else if !confirm.isEmpty && new != confirm {
                        Text("Passwords don't match.").font(.callout).foregroundStyle(.red)
                    }
                    Spacer()
                    Button(store.hasMasterPassword ? "Change Password" : "Set Password", action: save)
                        .disabled(new.isEmpty || new != confirm || (store.hasMasterPassword && current.isEmpty))
                }
                Text("One password unlocks every locked page. If you forget it, locked pages can't be recovered.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Auto-Lock") {
                HStack {
                    Text("Lock after")
                    TextField("", value: $minutes, format: .number)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $minutes, in: 0...1440).labelsHidden()
                    Text("minutes of inactivity")
                }
                Text("0 means never. Locked pages also lock when the Mac sleeps or the screen locks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: minutes) { value in minutes = min(max(value, 0), 1440) }
        .onChange(of: new) { _ in message = nil }
    }

    private func save() {
        if store.hasMasterPassword {
            isError = !store.changeMasterPassword(current: current, new: new)
            message = isError ? "Current password is incorrect." : "Password changed."
        } else {
            store.setMasterPassword(new)
            isError = !store.hasMasterPassword
            message = isError ? "Couldn't save the password." : "Password set."
        }
        current = ""
        new = ""
        confirm = ""
    }
}

struct ClaudeSettings: View {
    @AppStorage(Prefs.claudeBackend) private var backend = "claudeCode"
    @AppStorage(Prefs.claudeCodeModel) private var claudeCodeModel = "default"
    @AppStorage(Prefs.claudeUseCaveman) private var useCaveman = false
    @AppStorage(Prefs.claudeModel) private var model = Prefs.defaultModel
    @State private var cavemanPlugin = ClaudeCodeClient.cavemanPlugin

    private var cavemanNote: String {
        let requirement = "Requires the caveman plugin to be installed locally in Claude Code "
            + "(/plugin marketplace add JuliusBrussee/caveman, then install caveman)."
        guard let plugin = cavemanPlugin else { return requirement + " Not found on this Mac." }
        return requirement + " Found\(plugin.version.map { " v\($0)" } ?? "")."
    }
    @State private var key = Keychain.get(Keychain.apiKeyAccount) ?? ""
    @State private var status: String?
    @State private var account: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                Picker("Ask Claude using", selection: $backend) {
                    Text("Claude account (via Claude Code)").tag("claudeCode")
                    Text("API key").tag("api")
                }
            }
            if backend == "claudeCode" {
                Section("Claude Account") {
                    HStack {
                        Text(account ?? "Checking…").font(.callout)
                        Spacer()
                        if checking { ProgressView().controlSize(.small) }
                        Button("Check Again") { Task { await refreshAccount() } }.disabled(checking)
                    }
                    Picker("Model", selection: $claudeCodeModel) {
                        ForEach(ClaudeCodeClient.models) { Text($0.name).tag($0.id) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Use caveman (shorter answers)", isOn: $useCaveman)
                            .disabled(cavemanPlugin == nil && !useCaveman)
                        Text(cavemanNote).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Uses the Claude account you're logged in to in Claude Code, so questions count toward that plan's usage limits — no API key needed. To log in, run `claude` in Terminal once.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("API Key") {
                    SecureField("sk-ant-…", text: $key)
                    HStack {
                        Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                            .font(.callout)
                        Spacer()
                        if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                        Button("Save") {
                            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                            status = Keychain.set(trimmed, account: Keychain.apiKeyAccount)
                                ? (trimmed.isEmpty ? "Removed" : "Saved")
                                : "Couldn't save"
                        }
                    }
                    Text("Stored in your macOS Keychain, not in the app's files. Billed to your API account.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Model") {
                    Picker("Model", selection: $model) {
                        ForEach(ClaudeClient.models) { Text($0.name).tag($0.id) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: key) { _ in status = nil }
        .task(id: backend) { if backend == "claudeCode" { await refreshAccount() } }
    }

    private func refreshAccount() async {
        cavemanPlugin = ClaudeCodeClient.cavemanPlugin
        checking = true
        defer { checking = false }
        guard ClaudeCodeClient.executable != nil else {
            account = "Claude Code isn't installed."
            return
        }
        guard let status = await ClaudeCodeClient.status(), status.loggedIn else {
            account = "Not logged in — run `claude` in Terminal to log in."
            return
        }
        let plan = status.plan.map { " (\($0.capitalized))" } ?? ""
        account = "Logged in as \(status.email ?? "your Claude account")\(plan)"
    }
}

/// Opens the Settings window on every supported macOS version.
struct OpenSettingsButton: View {
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text("Open Settings…") }
        } else {
            Button("Open Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        }
    }
}

struct BackupSettings: View {
    @EnvironmentObject var store: Store

    var body: some View {
        BackupSettingsBody(store: store, backup: store.backup)
    }
}

/// Split out so the view observes the backup controller directly.
private struct BackupSettingsBody: View {
    @ObservedObject var store: Store
    @ObservedObject var backup: BackupController
    @AppStorage(Prefs.backupEnabled) private var enabled = false
    @AppStorage(Prefs.backupFrequency) private var frequency = BackupController.Frequency.daily.rawValue
    @AppStorage(Prefs.backupKeep) private var keep = 10
    @State private var restoring: BackupFile?
    @State private var restoredNote: String?

    private var hasICloud: Bool { BackupController.folder != nil }
    private var keysReady: Bool { store.backupKeyState == .ready }

    var body: some View {
        Form {
            Section {
                Toggle("Back up to iCloud Drive automatically", isOn: $enabled)
                    .disabled(!hasICloud || store.backupKeyState == .noPassword)
                Picker("How often", selection: $frequency) {
                    ForEach(BackupController.Frequency.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .disabled(!enabled)
                Stepper(value: $keep, in: 1...50) { Text("Keep the last \(keep) backup\(keep == 1 ? "" : "s")") }
                    .disabled(!enabled)
            } footer: {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusText).font(.callout)
                        if let error = backup.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        } else if let restoredNote {
                            Text(restoredNote).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if backup.isRunning { ProgressView().controlSize(.small) }
                }
                HStack {
                    Button("Back Up Now") { Task { await backup.backUpNow() } }
                        .disabled(!hasICloud || !keysReady || backup.isRunning)
                    Button("Show in Finder") { backup.showInFinder() }.disabled(!hasICloud)
                    Spacer()
                    Button("Restore…", action: chooseBackup).disabled(backup.isRunning)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { if $0 { backup.backUpIfDue() } }
        .sheet(item: $restoring) { file in
            RestoreSheet(backup: backup, file: file.url) { previous in
                restoredNote = "Restored. Your previous data was kept in \(previous.lastPathComponent)."
            }
        }
    }

    private var footer: String {
        if !hasICloud {
            return "iCloud Drive isn't available. Turn it on in System Settings › Apple Account › iCloud › iCloud Drive."
        }
        switch store.backupKeyState {
        case .noPassword:
            return "Backups are encrypted with your D-Scratch password, so set one in Settings › Security first."
        case .needsUnlock:
            return "Unlock your locked pages once to finish setting up encrypted backups."
        case .ready:
            return "Backups are encrypted on this Mac before they're saved to iCloud Drive › D-Scratch Backups, and are made only when something has changed. Restoring one needs the D-Scratch password that was set when it was made."
        }
    }

    private var statusText: String {
        if backup.isRunning { return "Backing up…" }
        guard let last = backup.lastBackup else { return "Not backed up yet." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last backup \(formatter.localizedString(for: last, relativeTo: Date()))."
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: BackupHeader.fileExtension) ?? .data]
        panel.directoryURL = BackupController.folder
        panel.message = "Choose a D-Scratch backup to restore"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        restoring = BackupFile(url: url)
    }
}

/// A backup file chosen for restoring.
private struct BackupFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Asks for the backup's password, then restores it.
private struct RestoreSheet: View {
    @ObservedObject var backup: BackupController
    let file: URL
    let onRestored: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore “\(file.deletingPathExtension().lastPathComponent)”").font(.headline)
            Text("All current pages, groups, tags and the D-Scratch password are replaced by the backup's. Your current data is kept in a “D-Scratch before restore” folder next to it, in case you need it back.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("D-Scratch password used for this backup", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(restore)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restore", role: .destructive, action: restore)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func restore() {
        guard !password.isEmpty, !working else { return }
        working = true
        Task {
            do {
                let previous = try await backup.restore(from: file, password: password)
                onRestored(previous)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                password = ""
            }
            working = false
        }
    }
}
