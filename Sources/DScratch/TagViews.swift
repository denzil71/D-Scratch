import SwiftUI

extension Tag {
    var swiftUIColor: Color { Color(nsColor: NSColor(hex: color) ?? .systemGray) }

    /// Black or white, whichever reads better on the tag colour.
    var textColor: Color {
        guard let c = NSColor(hex: color)?.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance > 0.62 ? .black : .white
    }
}

/// A coloured capsule for one tag. `onRemove` shows an ×; `inheritedFrom` marks a group tag.
struct TagChip: View {
    let tag: Tag
    var inheritedFrom: String?
    var onTap: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if inheritedFrom != nil {
                Image(systemName: "folder.fill").font(.system(size: 9))
            }
            Text(tag.name).font(.caption.weight(.medium)).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Remove tag")
            }
        }
        .foregroundStyle(tag.textColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tag.swiftUIColor))
        .contentShape(Capsule())
        .onTapGesture { onTap?() }
        .help(inheritedFrom.map { "From group “\($0)”. Click to search #\(tag.name)." } ?? "Click to search #\(tag.name)")
    }
}

/// Picks an existing tag or creates a new one. Return applies the top match or creates the typed name.
struct TagPicker: View {
    @EnvironmentObject var store: Store
    let applied: Set<UUID>
    let onPick: (Tag) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var clean: String { Store.normalizedTagName(text) }

    private var matches: [Tag] {
        store.tags
            .filter { !applied.contains($0.id) }
            .filter { clean.isEmpty || $0.name.localizedCaseInsensitiveContains(clean) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var canCreate: Bool {
        !clean.isEmpty && !store.tags.contains { $0.name.caseInsensitiveCompare(clean) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Tag name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if canCreate {
                        Button { create() } label: {
                            Label("Create “\(clean)”", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(matches) { tag in
                        TagChip(tag: tag, onTap: { pick(tag) })
                    }
                    if matches.isEmpty && !canCreate {
                        Text(store.tags.isEmpty ? "Type a name to create your first tag." : "No other tags.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .frame(width: 240)
        .onAppear { focused = true }
    }

    private func submit() {
        if let exact = store.tags.first(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            if !applied.contains(exact.id) { pick(exact) }
        } else if canCreate {
            create()
        } else if let first = matches.first {
            pick(first)
        }
    }

    private func create() {
        if let tag = store.createTag(named: clean) { pick(tag) }
    }

    private func pick(_ tag: Tag) {
        onPick(tag)
        text = ""
    }
}

/// The bar at the top of a page: its tags, tags from its group, and + to add more.
struct TagBar: View {
    @EnvironmentObject var store: Store
    let page: PageMeta
    @State private var picking = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag").foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.pageTags(page)) { tag in
                        TagChip(tag: tag, onTap: { search(tag) }, onRemove: { store.removeTag(tag.id, fromPage: page.id) })
                    }
                    ForEach(store.inheritedTags(of: page)) { tag in
                        TagChip(tag: tag, inheritedFrom: store.tagSource(tag.id, for: page), onTap: { search(tag) })
                    }
                    if store.effectiveTags(of: page).isEmpty {
                        Text("No tags").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button { picking = true } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Add a tag")
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    TagPicker(applied: Set((page.tagIDs ?? []))) { tag in
                        store.addTag(tag.id, toPage: page.id)
                    }
                    .environmentObject(store)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func search(_ tag: Tag) {
        store.searchQuery = "#\(tag.name)"
    }
}

/// Edits a group's tags (right-click a group → Tags…).
struct GroupTagsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let groupID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags for “\(store.name(of: groupID) ?? "Group")”").font(.headline)
            Text("Every page in this group and its subgroups gets these tags.").font(.callout).foregroundStyle(.secondary)
            let tags = store.groupTags(groupID)
            if tags.isEmpty {
                Text("No tags yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                FlowRow(tags) { tag in
                    TagChip(tag: tag, onRemove: { store.removeTag(tag.id, fromGroup: groupID) })
                }
            }
            Divider()
            TagPicker(applied: Set(tags.map(\.id))) { tag in store.addTag(tag.id, toGroup: groupID) }
                .padding(-12)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

/// Wraps chips onto multiple lines.
struct FlowRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        if #available(macOS 13, *) {
            WrapLayout(spacing: 6) { ForEach(items) { content($0) } }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (width: CGFloat, height: CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (maxX, y + rowHeight)
    }
}

/// Small colour dots for a sidebar row.
struct TagDots: View {
    let tags: [Tag]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(tags.prefix(4)) { tag in
                Circle().fill(tag.swiftUIColor).frame(width: 7, height: 7)
            }
        }
        .help(tags.map { "#\($0.name)" }.joined(separator: " "))
    }
}

/// Settings › Tags: rename, recolour, delete or add tags.
struct TagSettings: View {
    @EnvironmentObject var store: Store
    @State private var newName = ""
    @State private var deleting: Tag?

    var body: some View {
        Form {
            Section {
                if store.tags.isEmpty {
                    Text("No tags yet. Add one below, or from the tag bar at the top of a page.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(store.tags) { tag in
                    TagSettingsRow(tag: tag, onDelete: { deleting = tag })
                }
            } header: {
                Text("Tags")
            } footer: {
                Text("New tags get a random colour. Click a colour to change it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    TextField("New tag", text: $newName).onSubmit(add)
                    Button("Add", action: add).disabled(Store.normalizedTagName(newName).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete tag “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { tag in
            Button("Delete", role: .destructive) { store.deleteTag(tag.id) }
        } message: { tag in
            Text("It will be removed from \(store.usageCount(of: tag.id)) page(s) and group(s).")
        }
    }

    private func add() {
        store.createTag(named: newName)
        newName = ""
    }
}

struct TagSettingsRow: View {
    @EnvironmentObject var store: Store
    let tag: Tag
    let onDelete: () -> Void
    @State private var name = ""

    var body: some View {
        HStack {
            ColorPicker("", selection: Binding(
                get: { tag.swiftUIColor },
                set: { store.setTagColor(tag.id, NSColor($0).hexString) }
            ), supportsOpacity: false)
            .labelsHidden()
            TextField("", text: $name, prompt: Text("Name"))
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.plain)
                .onSubmit { store.renameTag(tag.id, to: name); name = tag.name }
                .help("Edit and press Return to rename")
            Text("\(store.usageCount(of: tag.id))").font(.caption).foregroundStyle(.secondary)
                .help("Pages and groups using this tag")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete tag")
        }
        .onAppear { name = tag.name }
        .onChange(of: tag.name) { name = $0 }
    }
}
