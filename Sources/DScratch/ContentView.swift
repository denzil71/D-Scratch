import SwiftUI
import UniformTypeIdentifiers

/// A request to lock pages that first needs the master password created or entered.
struct LockRequest: Identifiable {
    let id = UUID()
    let pageIDs: [UUID]
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
                ToolbarItemGroup {
                    Button { store.addGroup() } label: { Label("New Group", systemImage: "folder.badge.plus") }
                        .help("New group (⇧⌘N)")
                    Button { store.addPageNearSelection() } label: { Label("New Page", systemImage: "plus") }
                        .help("New page (⌘N)")
                }
            }
        } detail: {
            if let page = store.page(store.selection) {
                PageDetail(page: page, requestLock: { requestLock([$0.id]) })
            } else {
                Text("Select or create a page").foregroundStyle(.secondary)
            }
        }
        .alert("Rename", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let id = store.renamingID { store.rename(id, to: renameText) }
                store.renamingID = nil
            }
            Button("Cancel", role: .cancel) { store.renamingID = nil }
        }
        .onChange(of: store.renamingID) { id in
            renameText = store.name(of: id) ?? ""
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

    // MARK: Sidebar

    /// Top-level pages, then each group. Rows drag by page id; dropping on a list position
    /// or a group header moves the page there.
    private var pageList: some View {
        List(selection: $store.selection) {
            ForEach(store.pages(in: nil)) { pageRow($0) }
                .onInsert(of: [.plainText]) { index, providers in drop(providers, into: nil, at: index) }
            ForEach(store.groups) { group in
                DisclosureGroup(isExpanded: expandedBinding(group.id)) {
                    ForEach(store.pages(in: group.id)) { pageRow($0) }
                        .onInsert(of: [.plainText]) { index, providers in drop(providers, into: group.id, at: index) }
                } label: {
                    GroupRow(group: group, pages: store.pages(in: group.id), isUnlocked: store.isUnlocked)
                        .contentShape(Rectangle())
                        .onDrop(of: [.plainText], isTargeted: nil) { providers in
                            drop(providers, into: group.id, at: nil)
                            return true
                        }
                        .contextMenu { groupMenu(group) }
                }
            }
        }
    }

    private func pageRow(_ page: PageMeta) -> some View {
        PageRow(page: page, isOpen: store.isAccessible(page))
            .tag(page.id)
            .contextMenu { menu(for: page) }
            .itemProvider { NSItemProvider(object: page.id.uuidString as NSString) }
    }

    private func drop(_ providers: [NSItemProvider], into groupID: UUID?, at index: Int?) {
        for provider in providers {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? NSString, let id = UUID(uuidString: string as String) else { return }
                Task { @MainActor in store.movePage(id, toGroup: groupID, at: index) }
            }
        }
    }

    private func expandedBinding(_ groupID: UUID) -> Binding<Bool> {
        Binding(
            get: { store.groups.first { $0.id == groupID }?.isExpanded ?? true },
            set: { store.setExpanded(groupID, $0) })
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
                Section(resultTitle(pageID)) {
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

    private func resultTitle(_ pageID: UUID) -> String {
        guard let page = store.page(pageID) else { return "" }
        guard let group = store.name(of: page.groupID) else { return page.title }
        return "\(group) › \(page.title)"
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { store.renamingID != nil }, set: { if !$0 { store.renamingID = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private func requestLock(_ pageIDs: [UUID]) {
        guard !pageIDs.isEmpty else { return }
        if !store.hasMasterPassword {
            lockRequest = LockRequest(pageIDs: pageIDs, createPassword: true)
        } else if !store.isUnlocked {
            lockRequest = LockRequest(pageIDs: pageIDs, createPassword: false)
        } else {
            store.lockPages(pageIDs)
        }
    }

    // MARK: Context menus

    @ViewBuilder
    private func menu(for page: PageMeta) -> some View {
        let accessible = store.isAccessible(page)
        Button("Rename…") { store.renamingID = page.id }.disabled(!accessible)
        Menu("Move to Group") {
            Button("No Group") { store.movePage(page.id, toGroup: nil) }
                .disabled(page.groupID == nil)
            Divider()
            ForEach(store.groups) { group in
                Button(group.name) { store.movePage(page.id, toGroup: group.id) }
                    .disabled(page.groupID == group.id)
            }
            Divider()
            Button("New Group") {
                store.addGroup()
                if let group = store.groups.last { store.movePage(page.id, toGroup: group.id) }
            }
        }
        Divider()
        if !page.isLocked {
            Button("Lock Page") { requestLock([page.id]) }
        } else if accessible {
            Button("Remove Lock") { store.removeLock(page.id) }
        }
        if store.isUnlocked {
            Button("Lock All Pages Now") { store.lockAll() }
        }
        Divider()
        Button("Delete…", role: .destructive) { deleteTarget = page }.disabled(!accessible)
    }

    @ViewBuilder
    private func groupMenu(_ group: PageGroup) -> some View {
        let pages = store.pages(in: group.id)
        Button("New Page in Group") { store.addPage(inGroup: group.id) }
        Button("Rename Group…") { store.renamingID = group.id }
        Divider()
        Button("Lock All Pages in Group") { requestLock(pages.filter { !$0.isLocked }.map(\.id)) }
            .disabled(!pages.contains { !$0.isLocked })
        if store.isUnlocked && pages.contains(where: { $0.isLocked && !$0.isLegacyLocked }) {
            Button("Remove Locks in Group") { pages.filter(\.isLocked).forEach { store.removeLock($0.id) } }
        }
        Divider()
        Button("Delete Group (Keep Pages)") { store.removeGroup(group.id) }
    }
}

struct GroupRow: View {
    let group: PageGroup
    let pages: [PageMeta]
    let isUnlocked: Bool

    private var allLocked: Bool { !pages.isEmpty && pages.allSatisfy(\.isLocked) }

    var body: some View {
        HStack(spacing: 6) {
            Label(group.name, systemImage: "folder").lineLimit(1)
            Spacer()
            if allLocked {
                Image(systemName: isUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Every page in this group is locked")
            }
            Text("\(pages.count)").font(.caption).foregroundStyle(.secondary)
        }
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
                Button(request.pageIDs.count == 1 ? "Lock Page" : "Lock \(request.pageIDs.count) Pages", action: submit)
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
        store.lockPages(request.pageIDs)
        dismiss()
    }
}
