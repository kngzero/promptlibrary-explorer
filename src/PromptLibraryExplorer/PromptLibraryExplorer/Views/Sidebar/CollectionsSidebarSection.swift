import SwiftUI
import UniformTypeIdentifiers

/// Sidebar "Collections" section: hand-picked, cross-folder sets of files,
/// organised into nestable collection sets.
/// Styled like the Smart Folders section (inline header row, static "+").
struct CollectionsSidebarSection: View {
    @Environment(ExplorerViewModel.self) private var vm
    @AppStorage("sidebar.collections.expanded") private var isExpanded = true
    /// Comma-separated IDs of collapsed sets (sets start expanded).
    @AppStorage("sidebar.collectionSets.collapsed") private var collapsedSetsStorage = ""

    @State private var creation: CollectionCreationRequest?
    @State private var renamingID: UUID?
    @State private var pendingDelete: PendingCollectionDelete?
    @State private var isHeaderDropTarget = false
    @State private var filterText = ""

    private var filterQuery: String { filterText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isFiltering: Bool { !filterQuery.isEmpty }

    private var collapsedSets: Set<UUID> {
        Set(collapsedSetsStorage.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private var isEmpty: Bool { vm.collections.isEmpty && vm.collectionSets.isEmpty }

    var body: some View {
        if vm.explorerRootPath != nil || !isEmpty {
            Group {
                header
                    .sidebarSectionStart()
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    // Modals live on this single row. On the Group they'd be applied
                    // to EVERY row of the section inside the List, so each row
                    // presented its own copy (the "sheet opens 3 times" bug).
                    .sheet(item: $creation) { request in
                        NewCollectionSheet(
                            request: request,
                            parentName: request.parentID.flatMap { id in vm.collectionSets.first { $0.id == id }?.name },
                            selectedFileCount: vm.selectedFileItems.count
                        ) { name, withSelection in
                            creation = nil
                            switch request.kind {
                            case .collection:
                                vm.createCollection(named: name, withSelection: withSelection, inSet: request.parentID)
                            case .set:
                                vm.createCollectionSet(named: name, inSet: request.parentID)
                            }
                            isExpanded = true
                            if let parent = request.parentID { setCollapsed(parent, false) }
                        } onCancel: {
                            creation = nil
                        }
                    }
                    .alert(
                        pendingDelete?.title ?? "",
                        isPresented: Binding(
                            get: { pendingDelete != nil },
                            set: { if !$0 { pendingDelete = nil } }
                        ),
                        presenting: pendingDelete
                    ) { target in
                        Button("Delete", role: .destructive) {
                            switch target {
                            case .collection(let collection): vm.deleteCollection(collection.id)
                            case .set(let set): vm.deleteCollectionSet(set.id)
                            }
                            pendingDelete = nil
                        }
                        Button("Cancel", role: .cancel) { pendingDelete = nil }
                    } message: { target in
                        Text(target.message)
                    }

                if isExpanded {
                    if isEmpty {
                        Text("Drop files here or press + to start a collection")
                            .font(.appSidebarDetail)
                            .foregroundStyle(Color.appSidebarSecondaryText)
                            .padding(.leading, AppSpacing.xl + AppSpacing.xs)
                            .padding(.vertical, AppSpacing.xxs)
                            .selectionDisabled()
                    }

                    if !isEmpty {
                        SidebarFilterField(placeholder: "Filter Collections", text: $filterText)
                    }

                    let nodes = visibleNodes
                    ForEach(nodes) { node in
                        row(for: node)
                    }

                    if isFiltering, nodes.isEmpty {
                        Text("No collections match \u{201C}\(filterQuery)\u{201D}")
                            .font(.appSidebarDetail)
                            .foregroundStyle(Color.appSidebarSecondaryText)
                            .padding(.leading, AppSpacing.xl + AppSpacing.xs)
                            .padding(.vertical, AppSpacing.xxs)
                            .selectionDisabled()
                    }
                }
            }
        }
    }

    // MARK: Tree

    /// The tree flattened into rows, skipping the insides of collapsed sets.
    /// While filtering: a match shows with its enclosing sets (forced open), and a
    /// matching set shows everything inside it.
    private var visibleNodes: [CollectionTreeNode] {
        if isFiltering { return filteredNodes }
        var nodes: [CollectionTreeNode] = []
        let collapsed = collapsedSets
        var visited = Set<UUID>()
        func append(parent: UUID?, depth: Int) {
            let children = vm.collectionChildren(of: parent)
            for set in children.sets where visited.insert(set.id).inserted {
                nodes.append(.set(set, depth: depth))
                if !collapsed.contains(set.id) {
                    append(parent: set.id, depth: depth + 1)
                }
            }
            for collection in children.collections {
                nodes.append(.collection(collection, depth: depth))
            }
        }
        append(parent: nil, depth: 0)
        return nodes
    }

    private var filteredNodes: [CollectionTreeNode] {
        let query = filterQuery
        func matches(_ name: String) -> Bool {
            name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        var visited = Set<UUID>()
        func visit(parent: UUID?, ancestorMatched: Bool, depth: Int) -> [CollectionTreeNode] {
            var nodes: [CollectionTreeNode] = []
            let children = vm.collectionChildren(of: parent)
            for set in children.sets where visited.insert(set.id).inserted {
                let setMatched = ancestorMatched || matches(set.name)
                let inner = visit(parent: set.id, ancestorMatched: setMatched, depth: depth + 1)
                if setMatched || !inner.isEmpty {
                    nodes.append(.set(set, depth: depth))
                    nodes.append(contentsOf: inner)
                }
            }
            for collection in children.collections where ancestorMatched || matches(collection.name) {
                nodes.append(.collection(collection, depth: depth))
            }
            return nodes
        }
        return visit(parent: nil, ancestorMatched: false, depth: 0)
    }

    @ViewBuilder
    private func row(for node: CollectionTreeNode) -> some View {
        switch node {
        case .set(let set, let depth):
            CollectionSetSidebarRow(
                set: set,
                depth: depth,
                isCollapsed: !isFiltering && collapsedSets.contains(set.id),
                highlight: filterQuery,
                isRenaming: renamingID == set.id,
                onToggle: {
                    guard !isFiltering else { return }
                    setCollapsed(set.id, !collapsedSets.contains(set.id))
                },
                onCreate: { kind in creation = CollectionCreationRequest(kind: kind, parentID: set.id) },
                onBeginRename: { renamingID = set.id },
                onEndRename: { newName in
                    renamingID = nil
                    let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !trimmed.isEmpty, trimmed != set.name {
                        vm.renameCollectionSet(set.id, to: trimmed)
                    }
                },
                onRequestDelete: { pendingDelete = .set(set) },
                onExpand: { setCollapsed(set.id, false) }
            )
        case .collection(let collection, let depth):
            CollectionSidebarRow(
                collection: collection,
                depth: depth,
                highlight: filterQuery,
                isRenaming: renamingID == collection.id,
                onBeginRename: { renamingID = collection.id },
                onEndRename: { newName in
                    renamingID = nil
                    let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !trimmed.isEmpty, trimmed != collection.name {
                        vm.renameCollection(collection.id, to: trimmed)
                    }
                },
                onRequestDelete: { pendingDelete = .collection(collection) }
            )
        }
    }

    private func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        var ids = collapsedSets
        if collapsed { ids.insert(id) } else { ids.remove(id) }
        // Forget sets that no longer exist.
        let live = Set(vm.collectionSets.map(\.id))
        collapsedSetsStorage = ids.filter { live.contains($0) }.map(\.uuidString).sorted().joined(separator: ",")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.appIcon(10, weight: .bold))
                    .foregroundStyle(Color.appSidebarSecondaryText)
                    .frame(width: 12)

                Text("Collections")
                    .font(.appSidebarHeader)
                    .foregroundStyle(Color.appSidebarHeaderText)
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Collections")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits([.isButton, .isHeader])
            .accessibilityAction { isExpanded.toggle() }

            Spacer(minLength: 0)

            Menu {
                Button("New Collection…") {
                    creation = CollectionCreationRequest(kind: .collection, parentID: nil)
                }
                Button("New Collection Set…") {
                    creation = CollectionCreationRequest(kind: .set, parentID: nil)
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.appIcon(10, weight: .semibold))
                    .foregroundStyle(creation != nil ? Color.appAccent : Color.appSidebarSecondaryText)
            }
            // Plain button menu so the icon keeps the muted tint (borderless menus
            // draw their label in the primary colour).
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .fill(Color.appSurface.opacity(0.7))
            )
            .help("New Collection or Collection Set")
            .accessibilityLabel("New Collection or Collection Set")
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .strokeBorder(isHeaderDropTarget ? Color.appAccent : Color.clear, lineWidth: 1)
        )
        // The whole row (not just the title) toggles the section; the "+" menu
        // keeps its own click.
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
        .textCase(nil)
        // Dropping a set or collection on the header moves it to the top level.
        .onDrop(of: [UTType.plainText.identifier], isTargeted: $isHeaderDropTarget) { providers in
            Task {
                guard let item = await CollectionDragItem.load(from: providers) else { return }
                switch item {
                case .collection(let id): vm.moveCollection(id, toSet: nil)
                case .set(let id): vm.moveCollectionSet(id, toParent: nil)
                }
            }
            return true
        }
    }
}

// MARK: - Model helpers

private enum CollectionTreeNode: Identifiable {
    case set(CollectionSet, depth: Int)
    case collection(FileCollection, depth: Int)

    var id: UUID {
        switch self {
        case .set(let set, _): return set.id
        case .collection(let collection, _): return collection.id
        }
    }
}

struct CollectionCreationRequest: Identifiable {
    enum Kind { case collection, set }
    let id = UUID()
    let kind: Kind
    let parentID: UUID?
}

private enum PendingCollectionDelete {
    case collection(FileCollection)
    case set(CollectionSet)

    var title: String {
        switch self {
        case .collection(let collection): return "Delete \"\(collection.name)\"?"
        case .set(let set): return "Delete the set \"\(set.name)\"?"
        }
    }

    var message: String {
        switch self {
        case .collection:
            return "The collection is removed. The files themselves are not touched. This can't be undone."
        case .set:
            return "The set is removed and everything inside it moves up one level. No collections or files are deleted."
        }
    }
}

/// Drag payload for reorganising the tree: a plain-text token naming a set or collection.
enum CollectionDragItem {
    case collection(UUID)
    case set(UUID)

    private static let collectionPrefix = "plx-collection:"
    private static let setPrefix = "plx-collection-set:"

    var provider: NSItemProvider {
        switch self {
        case .collection(let id): return NSItemProvider(object: (Self.collectionPrefix + id.uuidString) as NSString)
        case .set(let id): return NSItemProvider(object: (Self.setPrefix + id.uuidString) as NSString)
        }
    }

    init?(token: String) {
        if token.hasPrefix(Self.setPrefix), let id = UUID(uuidString: String(token.dropFirst(Self.setPrefix.count))) {
            self = .set(id)
        } else if token.hasPrefix(Self.collectionPrefix),
                  let id = UUID(uuidString: String(token.dropFirst(Self.collectionPrefix.count))) {
            self = .collection(id)
        } else {
            return nil
        }
    }

    static func load(from providers: [NSItemProvider]) async -> CollectionDragItem? {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return nil }
        let token: String? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString) as String?)
            }
        }
        return token.flatMap(CollectionDragItem.init(token:))
    }
}

/// Indentation step for nested rows.
private let collectionTreeIndent: CGFloat = AppSpacing.lg + AppSpacing.xxs

// MARK: - Move menu

/// "Move to" submenu: Top Level plus every set, nested, minus `excluding` (a set and its descendants).
private struct CollectionMoveMenu: View {
    @Environment(ExplorerViewModel.self) private var vm
    let currentParentID: UUID?
    let excluding: Set<UUID>
    let onMove: (UUID?) -> Void

    var body: some View {
        Menu("Move to") {
            Button("Top Level") { onMove(nil) }
                .disabled(currentParentID == nil)
            let sets = vm.collectionChildren(of: nil).sets.filter { !excluding.contains($0.id) }
            if !sets.isEmpty {
                Divider()
                ForEach(sets) { set in
                    CollectionMoveTargets(set: set, currentParentID: currentParentID, excluding: excluding, onMove: onMove)
                }
            }
        }
    }
}

private struct CollectionMoveTargets: View {
    @Environment(ExplorerViewModel.self) private var vm
    let set: CollectionSet
    let currentParentID: UUID?
    let excluding: Set<UUID>
    let onMove: (UUID?) -> Void

    var body: some View {
        let subSets = vm.collectionChildren(of: set.id).sets.filter { !excluding.contains($0.id) }
        if subSets.isEmpty {
            Button(set.name) { onMove(set.id) }
                .disabled(currentParentID == set.id)
        } else {
            Menu(set.name) {
                Button("Into \"\(set.name)\"") { onMove(set.id) }
                    .disabled(currentParentID == set.id)
                Divider()
                ForEach(subSets) { child in
                    CollectionMoveTargets(set: child, currentParentID: currentParentID, excluding: excluding, onMove: onMove)
                }
            }
        }
    }
}

// MARK: - Set row

private struct CollectionSetSidebarRow: View {
    @Environment(ExplorerViewModel.self) private var vm

    let set: CollectionSet
    let depth: Int
    let isCollapsed: Bool
    var highlight = ""
    let isRenaming: Bool
    let onToggle: () -> Void
    let onCreate: (CollectionCreationRequest.Kind) -> Void
    let onBeginRename: () -> Void
    /// nil = rename cancelled.
    let onEndRename: (String?) -> Void
    let onRequestDelete: () -> Void
    let onExpand: () -> Void

    @State private var isDropTarget = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    /// True when the open collection lives somewhere inside this set.
    private var containsActiveCollection: Bool {
        guard let active = vm.activeCollection, let parent = active.parentID else { return false }
        return CollectionService.shared.descendantSetIDs(of: set.id, including: true).contains(parent)
    }

    var body: some View {
        let count = vm.collectionSetItemCount(set.id)
        interactiveRow(count: count)
            .contextMenu { menu }
            .accessibilityElement(children: isRenaming ? .contain : .ignore)
            .accessibilityLabel("Collection set \(set.name)")
            .accessibilityValue(accessibilityValue(count: count))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onToggle() }
            .accessibilityAction(named: "New Collection Inside") { onCreate(.collection) }
            .accessibilityAction(named: "New Set Inside") { onCreate(.set) }
            .accessibilityAction(named: "Rename") { onBeginRename() }
            .accessibilityAction(named: "Delete") { onRequestDelete() }
            .help(set.name)
    }

    private func accessibilityValue(count: Int) -> String {
        let state = isCollapsed ? "Collapsed" : "Expanded"
        let items = count == 1 ? "1 item" : "\(count) items"
        return "\(state), \(items)"
    }

    private func interactiveRow(count: Int) -> some View {
        styledRow(count: count)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isRenaming else { return }
                onToggle()
            }
            .onDrag { CollectionDragItem.set(set.id).provider }
            .onDrop(of: [UTType.plainText.identifier], isTargeted: $isDropTarget) { providers in
                Task { await handleDrop(providers) }
                return true
            }
    }

    private func styledRow(count: Int) -> some View {
        rowContent(count: count)
            .padding(.vertical, AppSpacing.xxs)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.leading, CGFloat(depth) * collectionTreeIndent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .fill(isDropTarget ? Color.appAccent.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .strokeBorder(isDropTarget ? Color.appAccent : Color.clear, lineWidth: 1)
            )
    }

    private func rowContent(count: Int) -> some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.appIcon(8, weight: .bold))
                .foregroundStyle(Color.appSidebarSecondaryText)
                .frame(width: 10)
                .accessibilityHidden(true)

            Image(systemName: isCollapsed ? "folder" : "folder.fill")
                .foregroundStyle(containsActiveCollection ? Color.appAccent : Color.appSidebarSecondaryText)
                .font(.appBody)
                .frame(width: 18)
                .accessibilityHidden(true)

            nameView

            Spacer(minLength: 0)

            Text("\(count)")
                .font(.appSidebarDetail)
                .monospacedDigit()
                .foregroundStyle(Color.appSidebarSecondaryText)
                .accessibilityHidden(true)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        guard let item = await CollectionDragItem.load(from: providers) else { return }
        switch item {
        case .collection(let id):
            vm.moveCollection(id, toSet: set.id)
            onExpand()
        case .set(let id):
            guard id != set.id else { return }
            if vm.moveCollectionSet(id, toParent: set.id) { onExpand() }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("New Collection in \"\(set.name)\"…") { onCreate(.collection) }
        Button("New Collection Set in \"\(set.name)\"…") { onCreate(.set) }
        Divider()
        Button("Rename") { onBeginRename() }
        CollectionMoveMenu(
            currentParentID: set.parentID,
            excluding: CollectionService.shared.descendantSetIDs(of: set.id, including: true)
        ) { target in
            vm.moveCollectionSet(set.id, toParent: target)
        }
        Divider()
        Button("Delete Set…", role: .destructive) { onRequestDelete() }
    }

    @ViewBuilder
    private var nameView: some View {
        if isRenaming {
            TextField("Set name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.appSidebarItem)
                .foregroundStyle(Color.appPrimaryText)
                .focused($nameFieldFocused)
                .onSubmit { onEndRename(draftName) }
                .onExitCommand { onEndRename(nil) }
                .onAppear {
                    draftName = set.name
                    DispatchQueue.main.async { nameFieldFocused = true }
                }
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused, isRenaming { onEndRename(draftName) }
                }
                .accessibilityLabel("Rename collection set \(set.name)")
        } else {
            Text(sidebarHighlighted(set.name, query: highlight))
                .font(.appSidebarItemEmphasis)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.appSidebarText)
        }
    }
}

// MARK: - Collection row

private struct CollectionSidebarRow: View {
    @Environment(ExplorerViewModel.self) private var vm

    let collection: FileCollection
    let depth: Int
    var highlight = ""
    let isRenaming: Bool
    let onBeginRename: () -> Void
    /// nil = rename cancelled.
    let onEndRename: (String?) -> Void
    let onRequestDelete: () -> Void

    @State private var isDropTarget = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    private var isActive: Bool { vm.activeCollectionID == collection.id }

    private var countLabel: String {
        "\(collection.paths.count)"
    }

    var body: some View {
        styledRow
            .accessibilityElement(children: isRenaming ? .contain : .ignore)
            .accessibilityLabel("Collection \(collection.name)")
            .accessibilityValue(collection.paths.count == 1 ? "1 item" : "\(collection.paths.count) items")
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { vm.openCollection(collection.id) }
            .accessibilityAction(named: "Rename") { onBeginRename() }
            .accessibilityAction(named: "Delete") { onRequestDelete() }
            .contextMenu { menu }
            .onDrag { CollectionDragItem.collection(collection.id).provider }
            .onDrop(of: [UTType.fileURL.identifier, UTType.plainText.identifier], isTargeted: $isDropTarget) { providers in
                Task { await handleDrop(providers) }
                return true
            }
            .help(collection.name)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open") { vm.openCollection(collection.id) }
        if !vm.selectedFileItems.isEmpty {
            Button("Add Selection to \"\(collection.name)\"") {
                vm.addSelection(toCollection: collection.id)
            }
        }
        Divider()
        Button("Send to Mood…") { vm.sendCollection(collection.id, to: .mood) }
            .disabled(collection.paths.isEmpty || vm.artOfficialSendProgress != nil)
        Button("Send to Story…") { vm.sendCollection(collection.id, to: .story) }
            .disabled(collection.paths.isEmpty || vm.artOfficialSendProgress != nil)
        Divider()
        Button("Rename") { onBeginRename() }
        CollectionMoveMenu(currentParentID: collection.parentID, excluding: []) { target in
            vm.moveCollection(collection.id, toSet: target)
        }
        Divider()
        Button("Delete…", role: .destructive) { onRequestDelete() }
    }

    private var rowFill: Color {
        if isActive { return .appSelected }
        return isDropTarget ? Color.appAccent.opacity(0.12) : .clear
    }

    private var styledRow: some View {
        rowContent
            .padding(.vertical, AppSpacing.xxs)
            .padding(.horizontal, AppSpacing.sm)
            // Collections line their icon up with a sibling set's folder icon (past its chevron).
            .padding(.leading, CGFloat(depth) * collectionTreeIndent + (depth > 0 ? 10 + AppSpacing.md : 0))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AppRadius.sm).fill(rowFill))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .strokeBorder(isDropTarget ? Color.appAccent : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isRenaming else { return }
                vm.activePane = .sidebar
                vm.openCollection(collection.id)
            }
    }

    @ViewBuilder
    private var nameView: some View {
        if isRenaming {
            TextField("Collection name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.appSidebarItem)
                .foregroundStyle(Color.appPrimaryText)
                .focused($nameFieldFocused)
                .onSubmit { onEndRename(draftName) }
                .onExitCommand { onEndRename(nil) }
                .onAppear {
                    draftName = collection.name
                    DispatchQueue.main.async { nameFieldFocused = true }
                }
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused, isRenaming { onEndRename(draftName) }
                }
                .accessibilityLabel("Rename collection \(collection.name)")
        } else {
            Text(sidebarHighlighted(collection.name, query: highlight))
                .font(.appSidebarItem)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isActive ? Color.appPrimaryText : Color.appSidebarText)
        }
    }

    private var rowContent: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: isActive ? "square.stack.fill" : "square.stack")
                .foregroundStyle(isActive ? Color.appAccent : Color.appSidebarSecondaryText)
                .font(.appBody)
                .frame(width: 18)
                .accessibilityHidden(true)

            nameView

            Spacer(minLength: 0)

            Text(countLabel)
                .font(.appSidebarDetail)
                .monospacedDigit()
                .foregroundStyle(Color.appSidebarSecondaryText)
                .accessibilityHidden(true)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        // A collection or set dragged onto a collection files it next to this one.
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if fileProviders.isEmpty {
            guard let item = await CollectionDragItem.load(from: providers) else { return }
            switch item {
            case .collection(let id):
                guard id != collection.id else { return }
                vm.moveCollection(id, toSet: collection.parentID)
            case .set(let id):
                vm.moveCollectionSet(id, toParent: collection.parentID)
            }
            return
        }

        let urls = await URLDropLoader.loadURLs(from: fileProviders)
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }

        // A drag of the current selection goes through the VM (toast + reload).
        let selected = Set(vm.selectedFileItems.map { $0.url.standardizedFileURL.path })
        if !selected.isEmpty, Set(paths) == selected {
            vm.addSelection(toCollection: collection.id)
            return
        }

        // Finder (or a partial) drag: add files only, skip folders.
        let files = paths.filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        guard !files.isEmpty else {
            vm.showToast("Only files can be added to a collection", type: .info)
            return
        }
        CollectionService.shared.add(paths: files, to: collection.id)
        vm.collections = CollectionService.shared.all()
        vm.showToast(
            "Added \(files.count) item\(files.count == 1 ? "" : "s") to \"\(collection.name)\"",
            type: .success
        )
        if vm.activeCollectionID == collection.id {
            await vm.reloadCollectionContents()
        }
    }
}

// MARK: - New collection / set sheet

private struct NewCollectionSheet: View {
    let request: CollectionCreationRequest
    let parentName: String?
    let selectedFileCount: Int
    let onCreate: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var includeSelection: Bool
    @FocusState private var fieldFocused: Bool

    init(
        request: CollectionCreationRequest,
        parentName: String?,
        selectedFileCount: Int,
        onCreate: @escaping (String, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.parentName = parentName
        self.selectedFileCount = selectedFileCount
        self.onCreate = onCreate
        self.onCancel = onCancel
        _includeSelection = State(initialValue: request.kind == .collection && selectedFileCount > 0)
    }

    private var isSet: Bool { request.kind == .set }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(isSet ? "New Collection Set" : "New Collection")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appPrimaryText)
                if let parentName {
                    Text("Inside \"\(parentName)\"")
                        .font(.appSidebarDetail)
                        .foregroundStyle(Color.appSidebarSecondaryText)
                } else if isSet {
                    Text("Sets hold collections and other sets.")
                        .font(.appSidebarDetail)
                        .foregroundStyle(Color.appSidebarSecondaryText)
                }
            }

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(create)
                .accessibilityLabel(isSet ? "Collection set name" : "Collection name")

            if !isSet, selectedFileCount > 0 {
                Button {
                    includeSelection.toggle()
                } label: {
                    HStack(spacing: AppSpacing.md) {
                        Image(systemName: includeSelection ? "checkmark.square.fill" : "square")
                            .font(.appBody)
                            .foregroundStyle(includeSelection ? Color.appAccent : Color.appMuted)
                        Text("Add \(selectedFileCount) selected file\(selectedFileCount == 1 ? "" : "s")")
                            .font(.appCallout)
                            .foregroundStyle(Color.appPrimaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(selectedFileCount) selected files")
                .accessibilityValue(includeSelection ? "On" : "Off")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(AppSpacing.xl)
        .frame(width: 300)
        .background(Color.appBackground)
        .onAppear { fieldFocused = true }
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        onCreate(trimmedName, !isSet && includeSelection && selectedFileCount > 0)
    }
}
