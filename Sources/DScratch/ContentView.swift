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
    @State private var deleteGroupTarget: PageGroup?
    @State private var groupTagsFor: UUID?
    @State private var hits: [SearchHit] = []

    var body: some View {
        NavigationSplitView {
            Group {
                if store.searchQuery.isEmpty { pageList } else { searchResults }
            }
            .searchable(text: $store.searchQuery, placement: .sidebar, prompt: "Search pages or #tags")
            .safeAreaInset(edge: .top) { tagFilterBar }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 380)
            .safeAreaInset(edge: .bottom, spacing: 0) { sidebarActions }
        } detail: {
            if let page = store.page(store.selection) {
                PageDetail(page: page, requestLock: { requestLock([$0.id]) })
            } else if let group = store.groups.first(where: { $0.id == store.selection }) {
                GroupSummary(group: group)
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
        .onChange(of: store.searchQuery) { hits = store.search($0) }
        .onChange(of: store.isUnlocked) { _ in hits = store.search(store.searchQuery) }
        .onChange(of: store.pages) { _ in hits = store.search(store.searchQuery) }
        .onChange(of: store.groups) { _ in hits = store.search(store.searchQuery) }
        .onChange(of: store.tags) { _ in hits = store.search(store.searchQuery) }
        .sheet(isPresented: Binding(get: { groupTagsFor != nil }, set: { if !$0 { groupTagsFor = nil } })) {
            if let id = groupTagsFor { GroupTagsSheet(groupID: id).environmentObject(store) }
        }
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
            ForEach(store.childGroups(of: nil)) { groupNode($0) }
        }
        .confirmationDialog(
            "Delete “\(deleteGroupTarget?.name ?? "")” and its pages?",
            isPresented: Binding(get: { deleteGroupTarget != nil }, set: { if !$0 { deleteGroupTarget = nil } }),
            presenting: deleteGroupTarget
        ) { group in
            Button("Delete Group and \(pageCount(group.id))", role: .destructive) { store.deleteGroupAndPages(group.id) }
        } message: { group in
            let subgroups = store.descendantGroupIDs(of: group.id).count - 1
            Text("The group\(subgroups > 0 ? ", its \(subgroups) subgroup\(subgroups == 1 ? "" : "s")," : "") and \(pageCount(group.id).lowercased()) in it will be deleted. This cannot be undone.")
        }
    }

    private func pageCount(_ groupID: UUID) -> String {
        let count = store.allPages(in: groupID).count
        return count == 1 ? "1 Page" : "\(count) Pages"
    }

    /// Always-visible New Page / New Group buttons at the bottom of the sidebar.
    private var sidebarActions: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                Button { store.addPageNearSelection() } label: { Label("New Page", systemImage: "plus") }
                    .help(newPageHelp)
                Button { store.addGroupNearSelection() } label: { Label("New Group", systemImage: "folder.badge.plus") }
                    .help(newGroupHelp)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var newPageHelp: String {
        if let group = store.name(of: store.selectionGroupID) { return "New page in “\(group)” (⌘N)" }
        return "New page (⌘N)"
    }

    private var newGroupHelp: String {
        if let group = store.name(of: store.selectionGroupID) { return "New group inside “\(group)” (⇧⌘N)" }
        return "New group (⇧⌘N)"
    }

    /// A group with its pages, then its subgroups (recursively).
    private func groupNode(_ group: PageGroup) -> AnyView {
        AnyView(
            DisclosureGroup(isExpanded: expandedBinding(group.id)) {
                ForEach(store.pages(in: group.id)) { pageRow($0) }
                    .onInsert(of: [.plainText]) { index, providers in drop(providers, into: group.id, at: index) }
                ForEach(store.childGroups(of: group.id)) { groupNode($0) }
            } label: {
                GroupRow(group: group, pages: store.allPages(in: group.id), isUnlocked: store.isUnlocked,
                         tags: store.groupTags(group.id))
                    .tag(group.id)
                    .contentShape(Rectangle())
                    .itemProvider { NSItemProvider(object: "group:\(group.id.uuidString)" as NSString) }
                    .onDrop(of: [.plainText], isTargeted: nil) { providers in
                        drop(providers, into: group.id, at: nil)
                        return true
                    }
                    .contextMenu { groupMenu(group) }
            }
        )
    }

    private func pageRow(_ page: PageMeta) -> some View {
        PageRow(page: page, isOpen: store.isAccessible(page), tags: store.effectiveTags(of: page))
            .tag(page.id)
            .contextMenu { menu(for: page) }
            .itemProvider { NSItemProvider(object: page.id.uuidString as NSString) }
    }

    /// Drops a page (its id) or a group ("group:<id>") into `groupID` (nil = top level).
    private func drop(_ providers: [NSItemProvider], into groupID: UUID?, at index: Int?) {
        for provider in providers {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = (object as? NSString) as String? else { return }
                if string.hasPrefix("group:"), let id = UUID(uuidString: String(string.dropFirst(6))) {
                    Task { @MainActor in store.moveGroup(id, to: groupID) }
                } else if let id = UUID(uuidString: string) {
                    Task { @MainActor in store.movePage(id, toGroup: groupID, at: index) }
                }
            }
        }
    }

    private func expandedBinding(_ groupID: UUID) -> Binding<Bool> {
        Binding(
            get: { store.groups.first { $0.id == groupID }?.isExpanded ?? true },
            set: { store.setExpanded(groupID, $0) })
    }

    /// Tag chips under the search field; clicking one adds or removes it as a #filter.
    @ViewBuilder
    private var tagFilterBar: some View {
        if !store.tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(store.tags.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { tag in
                        let active = store.searchQuery.split(whereSeparator: \.isWhitespace)
                            .contains { $0.caseInsensitiveCompare("#\(tag.name)") == .orderedSame }
                        TagChip(tag: tag, onTap: { store.toggleTagFilter(tag) })
                            .opacity(active || store.searchQuery.isEmpty ? 1 : 0.45)
                            .overlay(Capsule().stroke(Color.primary.opacity(active ? 0.6 : 0), lineWidth: 1.5))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
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
        guard let group = store.path(of: page.groupID) else { return page.title }
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
            ForEach(store.groupTree(), id: \.group.id) { item in
                Button(store.path(of: item.group.id) ?? item.group.name) { store.movePage(page.id, toGroup: item.group.id) }
                    .disabled(page.groupID == item.group.id)
            }
            Divider()
            Button("New Group") {
                store.addGroup(in: page.groupID)
                if let group = store.groups.last { store.movePage(page.id, toGroup: group.id) }
                store.selection = page.id
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
        let pages = store.allPages(in: group.id)
        let inside = store.descendantGroupIDs(of: group.id)
        Button("New Page in Group") { store.addPage(inGroup: group.id) }
        Button("New Subgroup") { store.addGroup(in: group.id) }
        Button("Rename Group…") { store.renamingID = group.id }
        Button("Tags…") { groupTagsFor = group.id }
        Menu("Move Group To") {
            Button("Top Level") { store.moveGroup(group.id, to: nil) }
                .disabled(group.parentID == nil)
            Divider()
            ForEach(store.groupTree().filter { !inside.contains($0.group.id) }, id: \.group.id) { item in
                Button(store.path(of: item.group.id) ?? item.group.name) { store.moveGroup(group.id, to: item.group.id) }
                    .disabled(group.parentID == item.group.id)
            }
        }
        Divider()
        Button("Lock All Pages in Group") { requestLock(pages.filter { !$0.isLocked }.map(\.id)) }
            .disabled(!pages.contains { !$0.isLocked })
        if store.isUnlocked && pages.contains(where: { $0.isLocked && !$0.isLegacyLocked }) {
            Button("Remove Locks in Group") { pages.filter(\.isLocked).forEach { store.removeLock($0.id) } }
        }
        Divider()
        Button(group.parentID == nil ? "Delete Group (Keep Pages)" : "Delete Group (Keep Pages in Parent)") {
            store.removeGroup(group.id)
        }
        Button("Delete Group and Pages…", role: .destructive) { deleteGroupTarget = group }
            .disabled(pages.contains { !store.isAccessible($0) })
    }
}

struct GroupRow: View {
    let group: PageGroup
    let pages: [PageMeta]
    let isUnlocked: Bool
    var tags: [Tag] = []

    private var allLocked: Bool { !pages.isEmpty && pages.allSatisfy(\.isLocked) }

    var body: some View {
        HStack(spacing: 6) {
            Label(group.name, systemImage: "folder").lineLimit(1)
            Spacer()
            if !tags.isEmpty { TagDots(tags: tags) }
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
    var tags: [Tag] = []

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(page.title).lineLimit(1)
                Spacer(minLength: 0)
                if !tags.isEmpty { TagDots(tags: tags) }
            }
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
                    TagBar(page: page)
                    Divider()
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

/// Shown when a group header is selected.
struct GroupSummary: View {
    @EnvironmentObject var store: Store
    let group: PageGroup

    var body: some View {
        let pages = store.allPages(in: group.id)
        let subgroups = store.descendantGroupIDs(of: group.id).count - 1
        let tags = store.groupTags(group.id)
        VStack(spacing: 12) {
            Image(systemName: "folder").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(group.name).font(.title2.bold())
            if let parent = store.path(of: group.parentID) {
                Text("in \(parent)").font(.callout).foregroundStyle(.secondary)
            }
            Text((pages.count == 1 ? "1 page" : "\(pages.count) pages")
                 + (subgroups > 0 ? " in \(subgroups + 1) groups" : "")).foregroundStyle(.secondary)
            if !tags.isEmpty {
                HStack(spacing: 6) { ForEach(tags) { TagChip(tag: $0) } }
            }
            HStack {
                Button { store.addPage(inGroup: group.id) } label: { Label("New Page in Group", systemImage: "plus") }
                    .keyboardShortcut(.defaultAction)
                Button { store.addGroup(in: group.id) } label: { Label("New Subgroup", systemImage: "folder.badge.plus") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(group.name)
    }
}
