import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the window appears; files opened before then wait in `pending`.
    weak var store: Store? {
        didSet {
            importPending()
            QuickCapture.shared.store = store
        }
    }
    private var pending: [URL] = []
    private let captureService = CaptureService()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before launch finishes so a Services request that launched the app is delivered.
        NSApp.servicesProvider = captureService
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSUpdateDynamicServices()
        GlobalHotKey.shared.onPress = { QuickCapture.shared.show() }
        GlobalHotKey.shared.apply()
    }

    /// Finder "Open With", drag onto the Dock icon, or `open -a D-Scratch file`.
    func application(_ application: NSApplication, open urls: [URL]) {
        pending.append(contentsOf: urls)
        importPending()
    }

    private func importPending() {
        guard let store, !pending.isEmpty else { return }
        for url in pending { store.importFile(url) }
        pending.removeAll()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// With a Quick Capture shortcut set, D-Scratch keeps running after its window closes so the shortcut still works.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        CaptureShortcut.current == nil
    }
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
                .onAppear { appDelegate.store = store }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Page") { store.addPageNearSelection() }.keyboardShortcut("n")
                Button("New Group") { store.addGroupNearSelection() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Quick Capture…") { QuickCapture.shared.show() }
            }
            CommandMenu("Format") {
                Button("Bold") { send(#selector(DTextView.toggleBold(_:))) }.keyboardShortcut("b")
                Button("Italic") { send(#selector(DTextView.toggleItalic(_:))) }.keyboardShortcut("i")
                Button("Underline") { send(#selector(DTextView.toggleUnderline(_:))) }.keyboardShortcut("u")
                Button("Code Block") { send(#selector(DTextView.toggleCodeBlock(_:))) }
                    .keyboardShortcut("k", modifiers: [.command, .option])
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
