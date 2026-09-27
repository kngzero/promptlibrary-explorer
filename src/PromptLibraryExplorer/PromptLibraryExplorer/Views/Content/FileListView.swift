import SwiftUI
import UniformTypeIdentifiers

/// An item of `processedFolderContents` together with its index there, so the
/// index-based selection API keeps working inside grouped sections.
struct IndexedEntry: Identifiable {
    let index: Int
    let item: FileEntry
    var id: String { item.id }
}

/// Which optional columns fit the current width.
struct FileListColumns: Equatable {
    var kind = true
    var model = true
    var rating = true
    var date = true
    var size = true
    var dimensions = true

    static let thumbnailWidth: CGFloat = 28
    static let kindWidth: CGFloat = 120
    static let modelWidth: CGFloat = 140
    static let ratingWidth: CGFloat = 76
    static let dateWidth: CGFloat = 140
    static let sizeWidth: CGFloat = 70
    static let dimensionsWidth: CGFloat = 90

    static func fitting(width: CGFloat) -> FileListColumns {
        var columns = FileListColumns()
        columns.model = width >= 820
        columns.dimensions = width >= 720
        columns.kind = width >= 620
        columns.size = width >= 540
        columns.date = width >= 460
        columns.rating = width >= 380
        return columns
    }
}

/// Sortable list layout of the content browser. Selection, drag-out and
/// double-click go through `FileDragSource`, exactly like grid tiles.
struct FileListView: View {
    @Environment(ExplorerViewModel.self) private var vm
    let groups: [ContentGroup]
    @Binding var collapsedGroups: Set<String>
    @Binding var inlineRenamePath: String?
    @Binding var inlineRenameValue: String
    let onRenameCommit: (FileEntry) -> Void
    let onRenameCancel: () -> Void
    let onRenameStart: (FileEntry) -> Void
    let onNewCollection: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let columns = FileListColumns.fitting(width: geometry.size.width)
            let items = vm.processedFolderContents

            VStack(spacing: 0) {
                FileListHeaderRow(columns: columns)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            if groups.isEmpty {
                                rows(for: items.indices.map { IndexedEntry(index: $0, item: items[$0]) }, columns: columns)
                            } else {
                                ForEach(groups) { group in
                                    let entries = group.indices
                                        .filter { $0 >= 0 && $0 < items.count }
                                        .map { IndexedEntry(index: $0, item: items[$0]) }
                                    Section {
                                        if !collapsedGroups.contains(group.id) {
                                            rows(for: entries, columns: columns)
                                        }
                                    } header: {
                                        ContentGroupHeader(
                                            title: group.title,
                                            count: entries.count,
                                            isCollapsed: collapsedGroups.contains(group.id),
                                            onToggle: { toggle(group.id) }
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.bottom, AppSpacing.md)
                    }
                    .onChange(of: vm.selectedItemIndex) { _, newIndex in
                        let items = vm.processedFolderContents
                        guard newIndex >= 0, newIndex < items.count else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(items[newIndex].id)
                        }
                    }
                }
            }
        }
        .task {
            // Up/down arrows move one row at a time in the list.
            if vm.gridColumnCount != 1 { vm.gridColumnCount = 1 }
        }
    }

    @ViewBuilder
    private func rows(for entries: [IndexedEntry], columns: FileListColumns) -> some View {
        ForEach(entries) { entry in
            FileListRow(
                item: entry.item,
                index: entry.index,
                columns: columns,
                inlineRenamePath: $inlineRenamePath,
                inlineRenameValue: $inlineRenameValue,
                onRenameCommit: { onRenameCommit(entry.item) },
                onRenameCancel: onRenameCancel
            )
            .id(entry.item.id)
            .contextMenu {
                ContentItemContextMenu(
                    item: entry.item,
                    index: entry.index,
                    onRename: { onRenameStart(entry.item) },
                    onNewCollection: onNewCollection
                )
            }
        }
    }

    private func toggle(_ id: String) {
        if collapsedGroups.contains(id) {
            collapsedGroups.remove(id)
        } else {
            collapsedGroups.insert(id)
        }
    }
}

// MARK: - Header

private struct FileListHeaderRow: View {
    @Environment(ExplorerViewModel.self) private var vm
    let columns: FileListColumns

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Color.clear.frame(width: FileListColumns.thumbnailWidth, height: 1)
            header("Name", field: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            if columns.kind {
                header("Kind", field: .type).frame(width: FileListColumns.kindWidth, alignment: .leading)
            }
            if columns.model {
                header("Model", field: nil).frame(width: FileListColumns.modelWidth, alignment: .leading)
            }
            if columns.rating {
                header("Rating", field: .rating).frame(width: FileListColumns.ratingWidth, alignment: .leading)
            }
            if columns.date {
                header("Date Modified", field: .dateModified).frame(width: FileListColumns.dateWidth, alignment: .leading)
            }
            if columns.size {
                header("Size", field: .size).frame(width: FileListColumns.sizeWidth, alignment: .trailing)
            }
            if columns.dimensions {
                header("Dimensions", field: nil).frame(width: FileListColumns.dimensionsWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .frame(height: 26)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appBorder).frame(height: 1)
        }
    }

    @ViewBuilder
    private func header(_ title: String, field: SortField?) -> some View {
        if let field {
            let isActive = vm.sortConfig.field == field
            Button {
                applySort(field)
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Text(title)
                        .font(.appCaptionEmphasis)
                        .foregroundStyle(isActive ? Color.appPrimaryText : Color.appMuted)
                        .lineLimit(1)
                    if isActive {
                        Image(systemName: Self.showsUpChevron(field, vm.sortConfig.direction) ? "chevron.up" : "chevron.down")
                            .font(.appIcon(8, weight: .bold))
                            .foregroundStyle(Color.appAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Sort by \(field.title)")
            .accessibilityLabel("Sort by \(field.title)")
            .accessibilityAddTraits(isActive ? [.isSelected] : [])
        } else {
            Text(title)
                .font(.appCaptionEmphasis)
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
        }
    }

    private func applySort(_ field: SortField) {
        if vm.sortConfig.field == field {
            vm.sortConfig.direction = vm.sortConfig.direction == .asc ? .desc : .asc
        } else {
            vm.sortConfig = SortConfig(field: field, direction: Self.defaultDirection(for: field))
        }
        vm.persistSortConfig()
    }

    /// Finder-like first click: newest / largest / best-rated first.
    private static func defaultDirection(for field: SortField) -> SortDirection {
        switch field {
        case .dateModified, .dateCreated, .size: return .desc
        default: return .asc   // rating's .asc is high-to-low in this app
        }
    }

    /// Up chevron = smallest value at the top. Rating's `.asc` is high-to-low.
    private static func showsUpChevron(_ field: SortField, _ direction: SortDirection) -> Bool {
        field == .rating ? direction == .desc : direction == .asc
    }
}

// MARK: - Row

private struct FileListRow: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: FileEntry
    let index: Int
    let columns: FileListColumns
    @Binding var inlineRenamePath: String?
    @Binding var inlineRenameValue: String
    let onRenameCommit: () -> Void
    let onRenameCancel: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isDropTarget = false
    @FocusState private var renameFieldFocused: Bool

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private var isSelected: Bool { vm.selectedIndices.contains(index) }
    private var isRenaming: Bool { inlineRenamePath == item.path }
    private var parameters: GenerationParameters? { vm.parametersByPath[item.path] }

    private var rowFill: Color {
        if isDropTarget { return Color.appAccent.opacity(0.12) }
        if isSelected { return Color.appSelected }
        return index.isMultiple(of: 2) ? Color.clear : Color.appSurface.opacity(0.45)
    }

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            thumbnailView
                .frame(width: FileListColumns.thumbnailWidth, height: FileListColumns.thumbnailWidth)

            nameView
                .frame(maxWidth: .infinity, alignment: .leading)

            if columns.kind {
                cell(FileKindDescriber.kind(for: item))
                    .frame(width: FileListColumns.kindWidth, alignment: .leading)
            }
            if columns.model {
                cell(parameters?.model ?? "")
                    .frame(width: FileListColumns.modelWidth, alignment: .leading)
            }
            if columns.rating {
                ratingView
                    .frame(width: FileListColumns.ratingWidth, alignment: .leading)
            }
            if columns.date {
                cell(item.modifiedDate.map { Self.dateFormatter.string(from: $0) } ?? "--")
                    .frame(width: FileListColumns.dateWidth, alignment: .leading)
            }
            if columns.size {
                cell(sizeText)
                    .monospacedDigit()
                    .frame(width: FileListColumns.sizeWidth, alignment: .trailing)
            }
            if columns.dimensions {
                cell(dimensionsText)
                    .monospacedDigit()
                    .frame(width: FileListColumns.dimensionsWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .frame(height: 34)
        .background(rowFill)
        .overlay(alignment: .leading) {
            if isSelected && vm.activePane == .content {
                Rectangle()
                    .fill(Color.appAccent)
                    .frame(width: 2)
            }
        }
        .overlay {
            if isDropTarget {
                Rectangle().strokeBorder(Color.appAccent.opacity(0.6), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .overlay {
            if !isRenaming {
                FileDragSource(
                    dragURLs: { ContentItemActions.dragURLs(for: item, at: index, vm: vm) },
                    isSelected: { isSelected },
                    onSelect: { modifiers in vm.selectItem(at: index, modifiers: modifiers) },
                    onDoubleClick: { ContentItemActions.open(item, at: index, vm: vm) },
                    externalOperation: { vm.externalDragOperation },
                    onDragEnded: { operation in
                        if operation.contains(.move) {
                            Task { await vm.refreshFolder() }
                        }
                    }
                )
            }
        }
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: item.isDirectory ? "Open Folder" : "Open") {
            ContentItemActions.open(item, at: index, vm: vm)
        }
        .accessibilityAction {
            ContentItemActions.open(item, at: index, vm: vm)
        }
        .task(id: item.id) {
            thumbnail = nil
            let loaded = await ContentThumbnailLoader.load(for: item, maxPixelSize: FileListColumns.thumbnailWidth * 2)
            guard !Task.isCancelled else { return }
            thumbnail = loaded
        }
        .modifier(FolderRowDropModifier(item: item, isDropTarget: $isDropTarget))
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: FileListColumns.thumbnailWidth, height: FileListColumns.thumbnailWidth)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous))
        } else {
            Image(systemName: ContentThumbnailLoader.iconName(for: item))
                .font(.appIcon(14))
                .foregroundStyle(item.isDirectory ? Color.appAccent.opacity(0.7) : Color.appMuted)
        }
    }

    @ViewBuilder
    private var nameView: some View {
        if isRenaming {
            TextField("", text: $inlineRenameValue)
                .textFieldStyle(.plain)
                .font(.appCallout)
                .foregroundStyle(Color.appPrimaryText)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xs)
                        .fill(Color.appSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.xs)
                        .strokeBorder(renameFieldFocused ? Color.appAccent : Color.appBorder, lineWidth: 1)
                )
                .focused($renameFieldFocused)
                .onSubmit(onRenameCommit)
                .onExitCommand(perform: onRenameCancel)
                .onKeyPress(.escape) {
                    onRenameCancel()
                    return .handled
                }
                .task(id: isRenaming) {
                    renameFieldFocused = isRenaming
                }
        } else {
            HStack(spacing: AppSpacing.xs) {
                Text(item.name)
                    .font(.appCallout)
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if vm.isFavorite(path: item.path) {
                    Image(systemName: "pin.fill")
                        .font(.appFootnote)
                        .foregroundStyle(Color.favoriteGoldText)
                        .accessibilityLabel("Pinned")
                }
            }
        }
    }

    @ViewBuilder
    private var ratingView: some View {
        let rating = vm.rating(for: item.path)
        if rating > 0 {
            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.appIcon(9))
                        .foregroundStyle(star <= rating ? Color.favoriteGoldText : Color.appMuted.opacity(0.4))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(rating) star\(rating == 1 ? "" : "s")")
        } else {
            Text("")
        }
    }

    private func cell(_ text: String) -> some View {
        Text(text)
            .font(.appCaption)
            .foregroundStyle(Color.appMuted)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var sizeText: String {
        guard !item.isDirectory, let size = item.fileSize else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var dimensionsText: String {
        guard let width = parameters?.width, let height = parameters?.height, width > 0, height > 0 else { return "--" }
        return "\(width)×\(height)"
    }

    private var accessibilityText: String {
        var parts = [item.name, FileKindDescriber.kind(for: item)]
        if let model = parameters?.model, !model.isEmpty { parts.append(model) }
        let rating = vm.rating(for: item.path)
        if rating > 0 { parts.append("\(rating) star\(rating == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

/// Folder rows accept drops: internal items move into the folder, Finder
/// files are imported into it. Non-folder rows let drops fall through to the
/// list's background (import into the current folder).
private struct FolderRowDropModifier: ViewModifier {
    @Environment(ExplorerViewModel.self) private var vm
    let item: FileEntry
    @Binding var isDropTarget: Bool

    func body(content: Content) -> some View {
        if item.isDirectory {
            content.onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
                let target = item.url
                Task {
                    let urls = await URLDropLoader.loadURLs(from: providers).map(\.standardizedFileURL)
                    guard !urls.isEmpty, !urls.contains(where: { $0.path == target.standardizedFileURL.path }) else { return }
                    let listed = Set(vm.processedFolderContents.map(\.path))
                    if urls.allSatisfy({ listed.contains($0.path) }) {
                        await vm.moveDraggedItems(urls, to: target)
                    } else {
                        await vm.importExternalFiles(urls, to: target)
                    }
                }
                return true
            }
        } else {
            content
        }
    }
}
