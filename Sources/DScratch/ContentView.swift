import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var renameText = ""
    @State private var lockTarget: PageMeta?
    @State private var deleteTarget: PageMeta?

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selection) {
                ForEach(store.pages) { page in
                    PageRow(page: page, isOpen: store.unlocked.contains(page.id))
                        .tag(page.id)
                        .contextMenu { menu(for: page) }
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 360)
            .toolbar {
                ToolbarItem {
                    Button { store.addPage() } label: { Label("New Page", systemImage: "plus") }
                        .help("New page (⌘N)")
                }
            }
        } detail: {
            if let page = store.page(store.selection) {
                PageDetail(page: page, lockTarget: $lockTarget)
            } else {
                Text("Select or create a page").foregroundStyle(.secondary)
            }
        }
        .alert("Rename Page", isPresented: renameBinding) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let id = store.renamingID { store.rename(id, to: renameText) }
                store.renamingID = nil
            }
            Button("Cancel", role: .cancel) { store.renamingID = nil }
        }
        .onChange(of: store.renamingID) { id in
            renameText = store.page(id)?.title ?? ""
        }
        .sheet(item: $lockTarget) { page in
            SetPasswordSheet(page: page).environmentObject(store)
        }
        .confirmationDialog(
            "Delete “\(deleteTarget?.title ?? "")”?", isPresented: deleteBinding, presenting: deleteTarget
        ) { page in
            Button("Delete", role: .destructive) { store.delete(page.id) }
        } message: { _ in
            Text("This cannot be undone.")
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { store.renamingID != nil }, set: { if !$0 { store.renamingID = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    @ViewBuilder
    private func menu(for page: PageMeta) -> some View {
        let accessible = store.isAccessible(page)
        Button("Rename…") { store.renamingID = page.id }.disabled(!accessible)
        Divider()
        if !page.isLocked {
            Button("Lock with Password…") { lockTarget = page }
        } else if accessible {
            Button("Lock Now") { store.relock(page.id) }
            Button("Remove Password") { store.removeLock(page.id) }
        }
        Divider()
        Button("Delete…", role: .destructive) { deleteTarget = page }.disabled(!accessible)
    }
}

struct PageRow: View {
    let page: PageMeta
    let isOpen: Bool

    var body: some View {
        Label {
            Text(page.title).lineLimit(1)
        } icon: {
            Image(systemName: page.isLocked ? (isOpen ? "lock.open.fill" : "lock.fill") : "doc.text")
        }
    }
}

struct PageDetail: View {
    @EnvironmentObject var store: Store
    let page: PageMeta
    @Binding var lockTarget: PageMeta?

    var body: some View {
        let accessible = store.isAccessible(page)
        Group {
            if accessible {
                RichTextEditor(pageID: page.id, store: store).id(page.id)
            } else {
                UnlockView(page: page).id(page.id)
            }
        }
        .navigationTitle(page.title)
        .toolbar {
            ToolbarItemGroup {
                if accessible {
                    Button { store.activeTextView?.insertMedia(nil) } label: {
                        Label("Insert Media", systemImage: "photo.on.rectangle")
                    }
                    .help("Insert image, video or audio (⇧⌘I)")
                }
                if !page.isLocked {
                    Button { lockTarget = page } label: { Label("Lock", systemImage: "lock") }
                        .help("Lock this page with a password")
                } else if accessible {
                    Button { store.relock(page.id) } label: { Label("Lock Now", systemImage: "lock.fill") }
                        .help("Hide this page until the password is entered")
                }
            }
        }
    }
}

struct UnlockView: View {
    @EnvironmentObject var store: Store
    let page: PageMeta
    @State private var password = ""
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(page.title).font(.title2.bold())
            Text("This page is locked.").foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($focused)
                .onSubmit(unlock)
            if failed {
                Text("Incorrect password").font(.callout).foregroundStyle(.red)
            }
            Button("Unlock", action: unlock)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        failed = !store.unlock(page.id, password: password)
        password = ""
    }
}

struct SetPasswordSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let page: PageMeta
    @State private var password = ""
    @State private var confirm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lock “\(page.title)”").font(.headline)
            SecureField("Password", text: $password)
            SecureField("Confirm password", text: $confirm)
            if !confirm.isEmpty && password != confirm {
                Text("Passwords don't match.").font(.callout).foregroundStyle(.red)
            }
            Text("If you forget this password, the page can't be recovered.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Lock") {
                    store.lock(page.id, password: password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || password != confirm)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 340)
    }
}
