import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            SecuritySettings().tabItem { Label("Security", systemImage: "lock") }
            ClaudeSettings().tabItem { Label("Claude", systemImage: "sparkles") }
        }
        .frame(width: 480, height: 400)
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
    @AppStorage(Prefs.claudeModel) private var model = Prefs.defaultModel
    @State private var key = Keychain.get(Keychain.apiKeyAccount) ?? ""
    @State private var status: String?

    var body: some View {
        Form {
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
                Text("Stored in your macOS Keychain, not in the app's files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Model") {
                Picker("Model", selection: $model) {
                    ForEach(ClaudeClient.models) { Text($0.name).tag($0.id) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: key) { _ in status = nil }
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
