import SwiftUI

/// A request to lock a page that first needs the master password created or entered.
struct LockRequest: Identifiable {
    let id = UUID()
    let pageID: UUID
    let createPassword: Bool
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var renameText = ""
    @State private var lockRequest: LockRequest?
    @State private var deleteTarget: PageMeta?
    @State private var query = ""
    @State private var hits: [SearchHit] = []

    var body: some View {
        NavigationSplitView {
            Group {
                if query.isEmpty { pageList } else { searchResults }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search all pages")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 380)
            .toolbar {
                ToolbarItem {
                    Button { store.addPage() } label: { Label("New Page", systemImage: "plus") }
                        .help("New page (⌘N)")
                }
            }
        } detail: {
            if let page = store.page(store.selection) {
                PageDetail(page: page, requestLock: requestLock)
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
        .onChange(of: query) { hits = store.search($0) }
        .onChange(of: store.isUnlocked) { _ in hits = store.search(query) }
        .onChange(of: store.pages) { _ in hits = store.search(query) }
        .sheet(item: $lockRequest) { request in
            LockSheet(request: request).environmentObject(store)
        }
        .confirmationDialog(
            "Delete “\(deleteTarget?.title ?? "")”?", isPresented: deleteBinding, presenting: deleteTarget
        ) { page in
            Button("Delete", role: .destructive) { store.delete(page.id) }
        } message: { _ in
            Text("This cannot be undone.")
        }
    }

    private var pageList: some View {
        List(selection: $store.selection) {
            ForEach(store.pages) { page in
                PageRow(page: page, isOpen: store.isAccessible(page))
                    .tag(page.id)
                    .contextMenu { menu(for: page) }
            }
            .onMove { store.move(from: $0, to: $1) }
        }
    }

    private var searchResults: some View {
        let pageIDs = hits.reduce(into: [UUID]()) { ids, hit in
            if !ids.contains(hit.pageID) { ids.append(hit.pageID) }
        }
        return List {
            if hits.isEmpty {
                Text("No matches").foregroundStyle(.secondary)
            }
            ForEach(pageIDs, id: \.self) { pageID in
                Section(store.page(pageID)?.title ?? "") {
                    ForEach(hits.filter { $0.pageID == pageID }) { hit in
                        Button { store.reveal(hit) } label: {
                            Text(hit.snippet)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !store.isUnlocked && store.pages.contains(where: \.isLocked) {
                Text("Locked pages aren't searched until you unlock them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { store.renamingID != nil }, set: { if !$0 { store.renamingID = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private func requestLock(_ page: PageMeta) {
        if !store.hasMasterPassword {
            lockRequest = LockRequest(pageID: page.id, createPassword: true)
        } else if !store.isUnlocked {
            lockRequest = LockRequest(pageID: page.id, createPassword: false)
        } else {
            store.lockPage(page.id)
        }
    }

    @ViewBuilder
    private func menu(for page: PageMeta) -> some View {
        let accessible = store.isAccessible(page)
        Button("Rename…") { store.renamingID = page.id }.disabled(!accessible)
        Divider()
        if !page.isLocked {
            Button("Lock Page") { requestLock(page) }
        } else if accessible {
            Button("Remove Lock") { store.removeLock(page.id) }
        }
        if store.isUnlocked {
            Button("Lock All Pages Now") { store.lockAll() }
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
    let requestLock: (PageMeta) -> Void

    var body: some View {
        let accessible = store.isAccessible(page)
        Group {
            if accessible {
                VStack(spacing: 0) {
                    AskClaudeBar(pageID: page.id).id(page.id)
                    Divider()
                    RichTextEditor(pageID: page.id, store: store, reveal: store.pendingReveal).id(page.id)
                }
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
                    Button { requestLock(page) } label: { Label("Lock Page", systemImage: "lock") }
                        .help("Lock this page with your D-Scratch password")
                } else if accessible {
                    Button { store.lockAll() } label: { Label("Lock All", systemImage: "lock.fill") }
                        .help("Hide all locked pages until the password is entered (⌘L)")
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

    /// A v0.1 page with its own password, reachable once the master password is entered.
    private var migrating: Bool { page.isLegacyLocked && store.isUnlocked }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(page.title).font(.title2.bold())
            if !store.hasMasterPassword {
                Text("Set a D-Scratch password in Settings to unlock this page.")
                    .foregroundStyle(.secondary)
                OpenSettingsButton()
            } else {
                Text(migrating
                     ? "This page still has its own password from an earlier version. Enter that password once to move it to your D-Scratch password."
                     : "Enter your D-Scratch password to unlock all locked pages.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                SecureField(migrating ? "This page's old password" : "Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .focused($focused)
                    .onSubmit(unlock)
                if failed {
                    Text("Incorrect password").font(.callout).foregroundStyle(.red)
                }
                Button(migrating ? "Unlock Page" : "Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
        .onChange(of: migrating) { _ in failed = false }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        failed = migrating
            ? !store.migrateLegacyPage(page.id, oldPassword: password)
            : !store.unlock(password: password)
        password = ""
    }
}

struct LockSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let request: LockRequest
    @State private var password = ""
    @State private var confirm = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.createPassword ? "Create a D-Scratch Password" : "Enter Your D-Scratch Password")
                .font(.headline)
            Text(request.createPassword
                 ? "One password locks and unlocks all of your locked pages. You can change it later in Settings."
                 : "Locking a page needs your password. This also unlocks your other locked pages.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
            if request.createPassword {
                SecureField("Confirm password", text: $confirm)
                if !confirm.isEmpty && password != confirm {
                    Text("Passwords don't match.").font(.callout).foregroundStyle(.red)
                }
                Text("If you forget this password, locked pages can't be recovered.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if failed {
                Text("Incorrect password").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Lock Page", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || (request.createPassword && password != confirm))
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 360)
    }

    private func submit() {
        if request.createPassword {
            store.setMasterPassword(password)
        } else if !store.unlock(password: password) {
            failed = true
            password = ""
            return
        }
        store.lockPage(request.pageID)
        dismiss()
    }
}
