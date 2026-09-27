import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared item actions (grid + list)

@MainActor
enum ContentItemActions {
    /// Double-click / VoiceOver default action: folders navigate, previewable
    /// files open in the lightbox.
    static func open(_ item: FileEntry, at index: Int, vm: ExplorerViewModel) {
        if item.isDirectory {
            // selectFolder leaves collection mode on its own.
            Task { await vm.selectFolder(item.url) }
        } else if FileHelpers.isPreviewable(item) {
            vm.lightboxIndex = index
            vm.lightboxOpen = true
        }
    }

    /// Makes `item` part of the selection before a context-menu action runs on
    /// the selection. A right-clicked item that is already selected keeps the
    /// whole selection; otherwise it becomes the only selected item.
    static func ensureSelected(_ item: FileEntry, at index: Int, vm: ExplorerViewModel) {
        guard !vm.selectedPaths.contains(item.path) else { return }
        let items = vm.processedFolderContents
        let resolved = (index >= 0 && index < items.count && items[index].path == item.path)
            ? index
            : items.firstIndex(where: { $0.path == item.path })
        if let resolved { vm.selectItem(at: resolved) }
    }

    /// Every selected file when `item` is part of a multi-selection, otherwise just `item`.
    static func dragURLs(for item: FileEntry, at index: Int, vm: ExplorerViewModel) -> [URL] {
        guard vm.selectedIndices.count > 1, vm.selectedIndices.contains(index) else {
            return [item.url]
        }
        return vm.selectedItems.map(\.url)
    }
}

// MARK: - Share sheet

@MainActor
enum SharePresenter {
    /// Shows the system share picker for `urls`, anchored at the mouse location
    /// in the key window (the context menu that triggered it has closed by then).
    static func share(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let screenPoint = NSEvent.mouseLocation
        // Let the context menu finish dismissing before presenting a popover.
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
                  let contentView = window.contentView
            else { return }
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let viewPoint = contentView.convert(windowPoint, from: nil)
            let anchor = NSRect(x: viewPoint.x - 1, y: viewPoint.y - 1, width: 2, height: 2)
            let picker = NSSharingServicePicker(items: urls)
            picker.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
        }
    }
}

// MARK: - Kind descriptions

enum FileKindDescriber {
    @MainActor private static var cache: [String: String] = [:]

    @MainActor
    static func kind(for item: FileEntry) -> String {
        if item.isDirectory { return "Folder" }
        let ext = item.url.pathExtension.lowercased()
        if ext == "plib" { return "Prompt Library" }
        if ext == "aoe" { return "Art Official Elements" }
        if ext.isEmpty { return "Document" }
        if let cached = cache[ext] { return cached }
        let description = UTType(filenameExtension: ext)?.localizedDescription ?? "\(ext.uppercased()) File"
        cache[ext] = description
        return description
    }
}

// MARK: - Thumbnails

enum ContentThumbnailLoader {
    /// Thumbnail for an image / video / .plib / .aoe entry, or nil for anything else.
    static func load(for item: FileEntry, maxPixelSize: CGFloat) async -> NSImage? {
        guard !item.isDirectory else { return nil }
        if FileHelpers.isImageFile(item.name) || FileHelpers.isVideoFile(item.name) {
            return await ThumbnailService.shared.thumbnail(for: item.url, size: maxPixelSize)
        }
        if FileHelpers.isPlibFile(item.name) || FileHelpers.isAoeFile(item.name) {
            return await snapshotThumbnail(for: item, maxPixelSize: maxPixelSize)
        }
        return nil
    }

    /// First image of a .plib/.aoe entry, downsampled and cached so the browser
    /// never holds (or re-parses for) full-resolution images.
    private static func snapshotThumbnail(for item: FileEntry, maxPixelSize: CGFloat) async -> NSImage? {
        let key = SnapshotThumbnailCache.key(for: item.url, maxPixelSize: maxPixelSize)
        if let cached = SnapshotThumbnailCache.shared.object(forKey: key) {
            return cached
        }

        let fullImage: NSImage?
        if FileHelpers.isPlibFile(item.name) {
            fullImage = await PlibParser.shared.parse(at: item.url)?.images.first
        } else {
            fullImage = await AoeParser.shared.parse(at: item.url)?.images.first
        }
        guard let fullImage, !Task.isCancelled else { return nil }

        let thumbnail = SnapshotThumbnailCache.downsample(fullImage, maxPixelSize: maxPixelSize) ?? fullImage
        SnapshotThumbnailCache.shared.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    static func iconName(for item: FileEntry) -> String {
        if item.isDirectory { return "folder.fill" }
        let name = item.name
        if FileHelpers.isPlibFile(name) { return "doc.text" }
        if FileHelpers.isAoeFile(name) { return "doc.richtext" }
        if FileHelpers.isVideoFile(name) { return "film" }
        if FileHelpers.isAudioFile(name) { return "waveform" }
        if FileHelpers.isImageFile(name) { return "photo" }
        return "doc"
    }
}

// MARK: - Group header

/// Section header for a grouped listing (grid and list).
struct ContentGroupHeader: View {
    let title: String
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "chevron.right")
                    .font(.appIcon(9, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(Color.appMuted)
                Text(title)
                    .font(.appCaptionEmphasis)
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(count)")
                    .font(.appMicro)
                    .foregroundStyle(Color.appMuted)
                    .padding(.horizontal, AppSpacing.xs)
                    .padding(.vertical, AppSpacing.xxs)
                    .background(Capsule().fill(Color.appElevatedSurface))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.appBackground.opacity(0.96))
        .help(isCollapsed ? "Expand \(title)" : "Collapse \(title)")
        .accessibilityLabel("\(title), \(count) item\(count == 1 ? "" : "s")")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Keyboard navigation layout

/// The on-screen arrangement of the listing, for arrow-key navigation: each
/// expanded group's items laid out in rows of `columns` (every group starts a
/// new row), collapsed groups contributing nothing. Indices are positions in
/// `processedFolderContents`.
struct ContentNavigationLayout {
    let rows: [[Int]]
    /// Visible items in on-screen order.
    let order: [Int]
    private let positions: [Int: (row: Int, column: Int)]

    init(itemCount: Int, groups: [ContentGroup], collapsedGroups: Set<String>, columns: Int) {
        let columns = max(1, columns)
        let sections: [[Int]]
        if groups.isEmpty {
            sections = [Array(0..<max(0, itemCount))]
        } else {
            sections = groups
                .filter { !collapsedGroups.contains($0.id) }
                .map { $0.indices.filter { $0 >= 0 && $0 < itemCount } }
        }

        var rows: [[Int]] = []
        for section in sections where !section.isEmpty {
            var start = 0
            while start < section.count {
                rows.append(Array(section[start..<min(section.count, start + columns)]))
                start += columns
            }
        }

        var positions: [Int: (row: Int, column: Int)] = [:]
        for (rowIndex, row) in rows.enumerated() {
            for (column, index) in row.enumerated() {
                positions[index] = (rowIndex, column)
            }
        }
        self.rows = rows
        self.order = rows.flatMap { $0 }
        self.positions = positions
    }

    func position(of index: Int) -> (row: Int, column: Int)? {
        positions[index]
    }

    /// Previous (`step` < 0) or next visible item in on-screen order. An index
    /// that isn't visible (inside a collapsed group) resolves to the nearest
    /// visible item on that side.
    func neighbor(of index: Int, step: Int) -> Int? {
        guard !order.isEmpty else { return nil }
        if let offset = order.firstIndex(of: index) {
            let target = offset + step
            return order.indices.contains(target) ? order[target] : nil
        }
        return step > 0 ? order.first(where: { $0 > index }) : order.last(where: { $0 < index })
    }

    /// Same column in the row above (`direction` < 0) or below, clamped to the
    /// last item of a shorter row; crosses group boundaries.
    func vertical(from index: Int, direction: Int) -> Int? {
        guard let position = position(of: index) else {
            return neighbor(of: index, step: direction)
        }
        let targetRow = position.row + (direction < 0 ? -1 : 1)
        guard rows.indices.contains(targetRow) else { return nil }
        let row = rows[targetRow]
        return row[min(position.column, row.count - 1)]
    }
}
