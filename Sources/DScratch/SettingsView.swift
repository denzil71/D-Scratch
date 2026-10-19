import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            SecuritySettings().tabItem { Label("Security", systemImage: "lock") }
            TagSettings().tabItem { Label("Tags", systemImage: "tag") }
            CodeSettings().tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            ClaudeSettings().tabItem { Label("Claude", systemImage: "sparkles") }
        }
        .frame(width: 480, height: 420)
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
