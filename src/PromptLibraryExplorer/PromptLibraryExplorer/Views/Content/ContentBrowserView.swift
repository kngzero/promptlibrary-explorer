import SwiftUI
import UniformTypeIdentifiers

struct ContentBrowserView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var inlineRenamePath: String?
    @State private var inlineRenameValue = ""
    @State private var reorderIndicator: ExplorerReorderIndicator?
    private let gridSpacing: CGFloat = 4
    private let gridPadding: CGFloat = 8

    private var itemSize: CGFloat {
        let base: CGFloat = 80
        let scale = CGFloat(vm.thumbnailSize)
        return base + (scale * 32) // 80..240
    }

    private var baseCellWidth: CGFloat {
        itemSize + 8
    }

    var body: some View {
        @Bindable var vm = vm

        VStack(spacing: 0) {
            HeaderBarView()

            if vm.isLoadingFolder {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.processedFolderContents.isEmpty {
                EmptyContentStateView(isFocused: vm.activePane == .content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let availableGridWidth = gridContentWidth(for: geometry.size.width)
                    let columnCount = fittedColumnCount(for: availableGridWidth)
                    let cellWidth = fittedCellWidth(for: availableGridWidth, columnCount: columnCount)
                    let fittedItemSize = max(80, cellWidth - 8)
                    let columns = Array(
                        repeating: GridItem(.flexible(minimum: cellWidth, maximum: cellWidth), spacing: gridSpacing),
                        count: columnCount
                    )

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: gridSpacing) {
                                ForEach(Array(vm.processedFolderContents.enumerated()), id: \.element.id) { index, item in
                                    ExplorerItemView(
                                        item: item,
                                        index: index,
                                        size: fittedItemSize,
                                        cellWidth: cellWidth,
                                        reorderIndicator: $reorderIndicator,
                                        inlineRenamePath: $inlineRenamePath,
                                        inlineRenameValue: $inlineRenameValue,
                                        onRenameCommit: { commitInlineRename(for: item) },
                                        onRenameCancel: cancelInlineRename
                                    )
                                        .id(item.id)
                                        .onTapGesture {
                                            let modifiers = EventModifiers(rawValue:
                                                (NSEvent.modifierFlags.contains(.shift) ? EventModifiers.shift.rawValue : 0) |
                                                (NSEvent.modifierFlags.contains(.command) ? EventModifiers.command.rawValue : 0)
                                            )
                                            vm.selectItem(at: index, modifiers: modifiers)
                                        }
                                        .simultaneousGesture(
                                            TapGesture(count: 2).onEnded {
                                                handleDoubleClick(item: item, index: index)
                                            }
                                        )
                                        .contextMenu {
                                            contextMenuItems(for: item)
                                        }
                                        .draggable(item.url) {
                                            Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
                                        }
                                }
                            }
                            .frame(width: availableGridWidth, alignment: .leading)
                            .overlayPreferenceValue(ExplorerItemBoundsPreferenceKey.self) { anchors in
                                GeometryReader { proxy in
                                    if let reorderIndicator,
                                       let anchor = anchors[reorderIndicator.itemPath]
                                    {
                                        ExplorerReorderIndicatorView(
                                            position: reorderIndicator.position,
                                            itemRect: proxy[anchor]
                                        )
                                    }
                                }
                            }
                            .padding(gridPadding)
                        }
                        .background {
                            Color.clear
                                .task(id: "\(Int(geometry.size.width.rounded())):\(columnCount)") {
                                    updateGridColumnCount(columnCount)
                                }
                        }
                        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                            Task {
                                let urls = await URLDropLoader.loadURLs(from: providers)
                                await vm.importExternalFiles(urls)
                            }
                            return true
                        }
                        .onChange(of: vm.selectedItemIndex) { _, newIndex in
                            if let inlineRenamePath {
                                let selectedPath =
                                    newIndex >= 0 && newIndex < vm.processedFolderContents.count
                                    ? vm.processedFolderContents[newIndex].path
                                    : nil
                                if selectedPath != inlineRenamePath {
                                    cancelInlineRename()
                                }
                            }

                            if newIndex >= 0, newIndex < vm.processedFolderContents.count {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    proxy.scrollTo(vm.processedFolderContents[newIndex].id, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }

            if vm.showStatusBar {
                ContentStatusBarView()
            }
        }
        .background(Color.appBackground)
        .onChange(of: vm.selectedFolderPath?.standardizedFileURL.path) { _, _ in
            cancelInlineRename()
        }
    }

    func handleDoubleClick(item: FileEntry, index: Int) {
        if item.isDirectory {
            Task { await vm.selectFolder(item.url) }
        } else if FileHelpers.isPreviewable(item) {
            vm.lightboxIndex = index
            vm.lightboxOpen = true
        }
    }

    @ViewBuilder
    private func contextMenuItems(for item: FileEntry) -> some View {
        Button("Reveal in Finder") {
            FileSystemService.revealInFinder(url: item.url)
        }

        Menu("Rate") {
            ForEach(1...5, id: \.self) { stars in
                Button {
                    vm.setRating(stars, for: item.path)
                } label: {
                    HStack {
                        Text(String(repeating: "\u{2605}", count: stars))
                        if vm.rating(for: item.path) == stars {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button("Clear Rating") {
                vm.setRating(0, for: item.path)
            }
            .disabled(vm.rating(for: item.path) == 0)
        }

        if !item.isDirectory, FileHelpers.isImageFile(item.name) {
            let apps = FileSystemService.applicationsForFile(url: item.url)
            if !apps.isEmpty {
                Menu("Open In...") {
                    ForEach(apps, id: \.self) { appURL in
                        Button(appURL.deletingPathExtension().lastPathComponent) {
                            FileSystemService.openFile(url: item.url, withApplication: appURL)
                        }
                    }
                }
            }
        }

        Divider()

        Button("Rename") {
            startInlineRename(for: item)
        }

        Button("Move") {
            let urls = contextMenuTargetItems(for: item).map(\.url)
            Task { await vm.moveItemsUsingFolderPicker(urls) }
        }

        Button("Move to Trash") {
            let urls = contextMenuTargetItems(for: item).map(\.url)
            Task { await vm.trashItems(at: urls) }
        }

        Button("Delete Permanently") {
            vm.requestPermanentDelete(for: contextMenuTargetItems(for: item))
        }
    }

    private func startInlineRename(for item: FileEntry) {
        inlineRenamePath = item.path
        inlineRenameValue = item.name
    }

    private func cancelInlineRename() {
        inlineRenamePath = nil
        inlineRenameValue = ""
    }

    private func commitInlineRename(for item: FileEntry) {
        let trimmed = inlineRenameValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            vm.showToast("Name cannot be empty.", type: .error)
            return
        }

        guard trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil else {
            vm.showToast("Name cannot contain path separators.", type: .error)
            return
        }

        if trimmed == item.name {
            cancelInlineRename()
            return
        }

        let url = item.url
        Task {
            if await vm.renameItem(at: url, to: trimmed) {
                cancelInlineRename()
            }
        }
    }

    private func contextMenuTargetItems(for item: FileEntry) -> [FileEntry] {
        if vm.selectedPaths.contains(item.path), !vm.selectedItems.isEmpty {
            return vm.selectedItems
        }
        return [item]
    }

    private func updateGridColumnCount(_ count: Int) {
        if vm.gridColumnCount != count {
            vm.gridColumnCount = count
        }
    }

    private func gridContentWidth(for availableWidth: CGFloat) -> CGFloat {
        max(availableWidth - (gridPadding * 2), baseCellWidth)
    }

    private func fittedColumnCount(for availableGridWidth: CGFloat) -> Int {
        max(1, Int((availableGridWidth + gridSpacing) / (baseCellWidth + gridSpacing)))
    }

    private func fittedCellWidth(for availableGridWidth: CGFloat, columnCount: Int) -> CGFloat {
        let totalSpacing = CGFloat(max(0, columnCount - 1)) * gridSpacing
        return (availableGridWidth - totalSpacing) / CGFloat(max(columnCount, 1))
    }
}

// MARK: - Explorer Item Cell

struct EmptyContentStateView: View {
    let isFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundStyle(isFocused ? Color.appAccent.opacity(0.85) : Color.appMuted)

            Text("No items to display")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isFocused ? Color.appPrimaryText : Color.appMuted)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.appSurface.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isFocused ? Color.appAccent : Color.appBorder, lineWidth: isFocused ? 1.5 : 1)
        )
    }
}

struct ContentStatusBarView: View {
    @Environment(ExplorerViewModel.self) private var vm

    var body: some View {
        HStack(spacing: 10) {
            Text(itemCountLabel)
                .font(.appCaption)
                .foregroundStyle(Color.appPrimaryText)

            Divider()
                .frame(height: 10)

            Text(hiddenCountLabel)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: LayoutMetrics.panelHeaderHeight)
        .background(Color.appBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.appBorder)
                .frame(height: 1)
        }
    }

    private var itemCountLabel: String {
        let count = vm.visibleItemCount
        return count == 1 ? "1 item" : "\(count) items"
    }

    private var hiddenCountLabel: String {
        let count = vm.hiddenItemCount
        return count == 1 ? "1 hidden" : "\(count) hidden"
    }
}

private struct ExplorerItemView: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: FileEntry
    let index: Int
    let size: CGFloat
    let cellWidth: CGFloat
    @Binding var reorderIndicator: ExplorerReorderIndicator?
    @Binding var inlineRenamePath: String?
    @Binding var inlineRenameValue: String
    let onRenameCommit: () -> Void
    let onRenameCancel: () -> Void

    @State private var thumbnail: NSImage?
    @State private var loadTaskID: String = ""
    @State private var isDropTarget = false
    @FocusState private var renameFieldFocused: Bool

    private var isSelected: Bool {
        vm.selectedIndices.contains(index)
    }

    private var isRenaming: Bool {
        inlineRenamePath == item.path
    }

    private var loadKey: String {
        "\(item.id)|\(Int(size.rounded()))"
    }

    private var badgeKind: PreviewBadgeKind? {
        if item.isDirectory { return nil }
        let name = item.name.lowercased()
        if name.hasSuffix(".plib") {
            return .plib
        } else if name.hasSuffix(".aoe") {
            return .aoe
        } else if FileHelpers.isImageFile(name) {
            return .image
        } else {
            return .file
        }
    }

    private var badgeSide: CGFloat {
        min(max(size * 0.22, 20), 30)
    }

    private var tileStrokeColor: Color {
        if isDropTarget {
            return Color.appAccent.opacity(0.8)
        }
        if isSelected && vm.activePane == .content {
            return Color.appAccent
        }
        return .clear
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipped()
                .cornerRadius(6)
        } else if item.isDirectory {
            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.35))
                .foregroundStyle(Color.appAccent.opacity(0.6))
        } else {
            Image(systemName: iconForFile(item.name))
                .font(.system(size: size * 0.25))
                .foregroundStyle(Color.appMuted)
        }
    }

    @ViewBuilder
    private var fileNameLabel: some View {
        if !vm.thumbnailsOnly {
            if isRenaming {
                TextField("", text: $inlineRenameValue)
                    .textFieldStyle(.plain)
                    .font(.appCaption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.appPrimaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(width: cellWidth - 8, alignment: .top)
                    .frame(minHeight: 38, alignment: .top)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.appSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(renameFieldFocused ? Color.appAccent : Color.appBorder, lineWidth: 1)
                    )
                    .focused($renameFieldFocused)
                    .onSubmit(onRenameCommit)
                    .onExitCommand(perform: onRenameCancel)
                    .task(id: isRenaming) {
                        renameFieldFocused = isRenaming
                    }
                    .onChange(of: isRenaming) { _, renaming in
                        renameFieldFocused = renaming
                    }
            } else {
                Text(item.name)
                    .font(.appCaption)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isSelected ? Color.appPrimaryText : Color.appMuted)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .frame(width: cellWidth, alignment: .top)
                    .frame(minHeight: 38, alignment: .top)
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    thumbnailView
                }
                .frame(width: size, height: size)
                .background(Color.appSurface)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(tileStrokeColor, lineWidth: 2)
                )
                .overlay(alignment: .topLeading) {
                    CompactStarBadge(rating: vm.rating(for: item.path))
                        .offset(x: 4, y: 4)
                        .allowsHitTesting(false)
                }

                if let badgeKind {
                    PreviewBadgeView(kind: badgeKind, side: badgeSide)
                        .offset(x: -3, y: -3)
                        .allowsHitTesting(false)
                }
            }

            fileNameLabel
        }
        .frame(width: cellWidth)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isSelected
                        ? Color.appSelected
                        : (isDropTarget ? Color.appAccent.opacity(0.1) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isDropTarget ? Color.appAccent.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .anchorPreference(key: ExplorerItemBoundsPreferenceKey.self, value: .bounds) {
            [item.path: $0]
        }
        .task(id: loadKey) {
            if loadTaskID != loadKey {
                thumbnail = nil
                loadTaskID = loadKey
            }
            await loadThumbnail()
        }
        .onChange(of: loadKey) { _, newKey in
            if loadTaskID != newKey {
                thumbnail = nil
                loadTaskID = newKey
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            delegate: ExplorerItemDropDelegate(
                item: item,
                cellWidth: cellWidth,
                isDropTarget: $isDropTarget,
                reorderIndicator: $reorderIndicator,
                prepareForReorder: { vm.ensureCustomSortForCurrentFolder() },
                dropHandler: { urls, intent in
                    handleDrop(urls, intent: intent)
                }
            )
        )
    }

    private func loadThumbnail() async {
        guard !item.isDirectory else { return }
        let expectedID = item.id

        let loaded: NSImage?
        if FileHelpers.isImageFile(item.name) {
            loaded = await ThumbnailService.shared.thumbnail(for: item.url, size: size * 2)
        } else if FileHelpers.isPlibFile(item.name) {
            if let entry = await PlibParser.shared.parse(at: item.url) {
                loaded = entry.images.first
            } else { loaded = nil }
        } else if FileHelpers.isAoeFile(item.name) {
            if let entry = await AoeParser.shared.parse(at: item.url) {
                loaded = entry.images.first
            } else { loaded = nil }
        } else {
            loaded = nil
        }

        guard !Task.isCancelled, item.id == expectedID else { return }
        thumbnail = loaded
    }

    private func iconForFile(_ name: String) -> String {
        if FileHelpers.isPlibFile(name) { return "doc.text" }
        if FileHelpers.isAoeFile(name) { return "doc.richtext" }
        if FileHelpers.isImageFile(name) { return "photo" }
        return "doc"
    }

    private func handleDrop(_ urls: [URL], intent: ExplorerDropIntent?) -> Bool {
        let standardizedURLs = urls.map(\.standardizedFileURL)
        guard let sourceURL = standardizedURLs.first else { return false }
        let availablePaths = Set(vm.processedFolderContents.map(\.path))
        let isInternalDrag = standardizedURLs.allSatisfy { availablePaths.contains($0.path) }

        if item.isDirectory, !isInternalDrag {
            Task { await vm.importExternalFiles(standardizedURLs, to: item.url) }
            return true
        }

        if intent == .moveIntoFolder {
            Task { await vm.moveDraggedItems(standardizedURLs, to: item.url) }
            return true
        }

        guard case let .reorder(position)? = intent else { return false }

        let sourcePath = sourceURL.path
        guard availablePaths.contains(sourcePath) else { return false }

        let sourcePaths: [String]
        if vm.selectedPaths.contains(sourcePath), vm.selectedIndices.count > 1 {
            sourcePaths = vm.selectedPaths
        } else {
            sourcePaths = [sourcePath]
        }

        let sourceIndices = sourcePaths.compactMap { path in
            vm.processedFolderContents.firstIndex(where: { $0.path == path })
        }
        guard !sourceIndices.isEmpty else { return false }

        vm.reorderItems(sourcePaths: sourcePaths, targetPath: item.path, position: position)
        return true
    }
}

private enum PreviewBadgeKind {
    case plib
    case aoe
    case image
    case file
}

private struct PreviewBadgeView: View {
    let kind: PreviewBadgeKind
    let side: CGFloat

    private var backgroundColor: Color {
        switch kind {
        case .plib, .aoe:
            return Color(red: 0xd9 / 255.0, green: 0x00 / 255.0, blue: 0xd9 / 255.0)
        case .image:
            return .segmentBrief
        case .file:
            return .appElevatedSurface
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.18, style: .continuous)
                .fill(backgroundColor)

            glyph
                .foregroundStyle(.white)
                .padding(side * 0.14)
        }
        .frame(width: side, height: side)
        .shadow(color: Color.appShadowColor.opacity(0.85), radius: side * 0.1, y: side * 0.04)
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .plib:
            PlibPreviewGlyph()
        case .aoe:
            AoePreviewGlyph()
        case .image:
            Image(systemName: "photo.fill")
                .font(.system(size: side * 0.54, weight: .semibold))
        case .file:
            Image(systemName: "doc.fill")
                .font(.system(size: side * 0.54, weight: .semibold))
        }
    }
}

private struct ExplorerReorderIndicator: Equatable {
    let itemPath: String
    let position: ReorderPosition
}

private struct ExplorerItemBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct ExplorerReorderIndicatorView: View {
    let position: ReorderPosition
    let itemRect: CGRect

    var body: some View {
        Rectangle()
            .fill(Color.appAccent)
            .frame(width: 3, height: max(itemRect.height - 12, 0))
            .position(
                x: position == .after ? (itemRect.maxX - 2) : (itemRect.minX + 2),
                y: itemRect.midY
            )
            .allowsHitTesting(false)
    }
}

private struct PlibPreviewGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let topLeft = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.08)
        let topRight = CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.minY + rect.height * 0.24)
        let rightMid = CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.midY + rect.height * 0.18)
        let bottom = CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.08)
        let leftMid = CGPoint(x: rect.minX + rect.width * 0.14, y: rect.midY + rect.height * 0.18)
        let topLeftShoulder = CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.24)
        let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.02)

        var path = Path()

        path.move(to: topLeft)
        path.addLine(to: topRight)
        path.addLine(to: center)
        path.addLine(to: topLeftShoulder)
        path.closeSubpath()

        path.move(to: topLeftShoulder)
        path.addLine(to: center)
        path.addLine(to: center.applying(.init(translationX: 0, y: rect.height * 0.02)))
        path.addLine(to: bottom)
        path.addLine(to: leftMid)
        path.closeSubpath()

        path.move(to: center)
        path.addLine(to: topRight)
        path.addLine(to: rightMid)
        path.addLine(to: bottom)
        path.addLine(to: center.applying(.init(translationX: 0, y: rect.height * 0.02)))
        path.closeSubpath()

        return path
    }
}

private struct AoePreviewGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centerX = rect.midX
        let widths: [CGFloat] = [
            rect.width * 0.64,
            rect.width * 0.76,
            rect.width * 0.82,
            rect.width * 0.72,
        ]
        let yPositions: [CGFloat] = [
            rect.minY + rect.height * 0.24,
            rect.minY + rect.height * 0.40,
            rect.minY + rect.height * 0.57,
            rect.minY + rect.height * 0.74,
        ]
        let layerHeight = rect.height * 0.16

        for (index, width) in widths.enumerated() {
            let y = yPositions[index]
            let inset = width * 0.18
            let topLeft = CGPoint(x: centerX - width / 2, y: y)
            let topRight = CGPoint(x: centerX + width / 2, y: y)
            let bottomRight = CGPoint(x: centerX + width / 2 - inset, y: y + layerHeight)
            let bottomLeft = CGPoint(x: centerX - width / 2 + inset, y: y + layerHeight)

            path.move(to: topLeft)
            path.addLine(to: topRight)
            path.addLine(to: bottomRight)
            path.addLine(to: bottomLeft)
            path.closeSubpath()
        }

        return path
    }
}

enum ExplorerDropIntent: Equatable {
    case moveIntoFolder
    case reorder(ReorderPosition)
}

private struct ExplorerItemDropDelegate: DropDelegate {
    let item: FileEntry
    let cellWidth: CGFloat
    @Binding var isDropTarget: Bool
    @Binding var reorderIndicator: ExplorerReorderIndicator?
    let prepareForReorder: () -> Void
    let dropHandler: ([URL], ExplorerDropIntent?) -> Bool

    func dropEntered(info: DropInfo) {
        let intent = resolvedIntent(for: info.location.x)
        updatePreview(for: intent)
        if case .reorder? = intent {
            prepareForReorder()
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let intent = resolvedIntent(for: info.location.x)
        updatePreview(for: intent)
        if case .reorder? = intent {
            prepareForReorder()
        }
        switch intent {
        case .moveIntoFolder:
            return DropProposal(operation: .copy)
        case .reorder:
            return DropProposal(operation: .move)
        case nil:
            return nil
        }
    }

    func dropExited(info: DropInfo) {
        resetPreview()
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL.identifier])
        guard !providers.isEmpty else {
            resetPreview()
            return false
        }

        let dropIntent = resolvedIntent(for: info.location.x)
        Task {
            let urls = await loadURLs(from: providers)
            _ = await MainActor.run {
                dropHandler(urls, dropIntent)
            }
        }

        resetPreview()
        return true
    }

    private func updatePreview(for intent: ExplorerDropIntent?) {
        switch intent {
        case .moveIntoFolder:
            isDropTarget = true
            clearReorderIndicator()
        case let .reorder(position):
            isDropTarget = false
            reorderIndicator = ExplorerReorderIndicator(itemPath: item.path, position: position)
        case nil:
            resetPreview()
        }
    }

    private func resetPreview() {
        isDropTarget = false
        clearReorderIndicator()
    }

    private func clearReorderIndicator() {
        if reorderIndicator?.itemPath == item.path {
            reorderIndicator = nil
        }
    }

    private func resolvedIntent(for x: CGFloat) -> ExplorerDropIntent? {
        if item.isDirectory {
            let edgeThreshold = min(max(cellWidth * 0.18, 24), 48)
            if x <= edgeThreshold {
                return .reorder(.before)
            }
            if x >= (cellWidth - edgeThreshold) {
                return .reorder(.after)
            }
            return .moveIntoFolder
        }

        return .reorder(x >= (cellWidth / 2) ? .after : .before)
    }

    private func loadURLs(from providers: [NSItemProvider]) async -> [URL] {
        await URLDropLoader.loadURLs(from: providers)
    }
}
