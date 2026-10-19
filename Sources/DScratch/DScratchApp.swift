import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DScratchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store()

    var body: some Scene {
        Window("D-Scratch", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 460)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Page") { store.addPage() }.keyboardShortcut("n")
            }
            CommandMenu("Format") {
                Button("Bold") { send(#selector(DTextView.toggleBold(_:))) }.keyboardShortcut("b")
                Button("Italic") { send(#selector(DTextView.toggleItalic(_:))) }.keyboardShortcut("i")
                Button("Underline") { send(#selector(DTextView.toggleUnderline(_:))) }.keyboardShortcut("u")
                Divider()
                Button("Show Fonts") { NSFontManager.shared.orderFrontFontPanel(nil) }.keyboardShortcut("t")
                Button("Show Colors") { NSApp.orderFrontColorPanel(nil) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CommandMenu("Page") {
                Button("Insert Media…") { store.activeTextView?.insertMedia(nil) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Lock All Pages") { store.lockAll() }
                    .keyboardShortcut("l")
                    .disabled(!store.isUnlocked)
            }
        }

        Settings {
            SettingsView().environmentObject(store)
        }
    }

    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
