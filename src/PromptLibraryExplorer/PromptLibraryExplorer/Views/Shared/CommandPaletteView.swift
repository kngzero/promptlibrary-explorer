import SwiftUI

/// A Cmd+K command palette overlay for quick filtering, navigation, and actions.
struct CommandPaletteView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var fileHits: [LibrarySearchHit] = []
    @State private var isSearchingFiles = false
    @State private var highlightedIndex = 0
    @FocusState private var isFocused: Bool

    private static let fileSearchDebounce: Duration = .milliseconds(150)

    /// Every row in display order, grouped into titled sections. Keyboard
    /// navigation walks the flattened list across sections.
    private var sections: [(title: String, items: [CommandPaletteItem])] {
        var byTitle: [(String, [CommandPaletteItem])] = []
        var current: (String, [CommandPaletteItem])?
        for item in results {
            let title = item.sectionTitle
            if current?.0 == title {
                current?.1.append(item)
            } else {
                if let current { byTitle.append(current) }
                current = (title, [item])
            }
        }
        if let current { byTitle.append(current) }
        let help = helpItems
        if !help.isEmpty {
            byTitle.append(("Help", help))
        }
        if !fileHits.isEmpty {
            byTitle.append(("Files", fileHits.map { CommandPaletteItem.file($0) }))
        }
        return byTitle.map { (title: $0.0, items: $0.1) }
    }

    private var flatItems: [CommandPaletteItem] {
        sections.flatMap(\.items)
    }

    /// "Help: …" rows: every Help topic and tip is findable by name. Only while
    /// typing, so the empty palette stays short.
    private var helpItems: [CommandPaletteItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var items: [CommandPaletteItem] = []
        let general: [(String, String, () -> Void)] = [
            ("Help: Welcome Tour", "sparkles", { vm.presentWelcomeTour() }),
            ("Help: Keyboard Shortcuts", "command", { vm.openHelp(focus: .section(.keyboard)) }),
            ("Help: All Topics", "questionmark.circle", { vm.openHelp() }),
            ("Help: Reset Tips", "lightbulb", { vm.resetTips() }),
        ]
        for (name, icon, action) in general where HelpPaletteMatch.matches(q, texts: [name]) {
            items.append(.help(name: name, icon: icon, action: action))
        }
        for entry in HelpContent.referenceEntries where HelpPaletteMatch.matches(q, entry: entry) {
            items.append(.help(name: "Help: \(entry.title)", icon: entry.section.icon) {
                vm.openHelp(focus: .entry(entry.id))
            })
        }
        return Array(items.prefix(8))
    }

    private var results: [CommandPaletteItem] {
        let q = query.lowercased()
        var items: [CommandPaletteItem] = []

        // Folders
        for folder in vm.sidebarFolders where q.isEmpty || folder.name.lowercased().contains(q) {
            items.append(.folder(folder))
        }

        // Smart Folders
        for sf in vm.smartFolders where q.isEmpty || sf.name.lowercased().contains(q) {
            items.append(.smartFolder(sf))
        }

        // Tags
        for tag in vm.allTags where q.isEmpty || tag.name.lowercased().contains(q) {
            items.append(.tag(tag))
        }

        // Actions
        var actions: [(String, String, () -> Void)] = []

        if vm.canNavigateBack {
            actions.append(("Back", "chevron.backward", { Task { await vm.navigateBack() } }))
        }
        if vm.canNavigateForward {
            actions.append(("Forward", "chevron.forward", { Task { await vm.navigateForward() } }))
        }

        actions += [
            ("Open Folder...", "folder.badge.plus", { Task { await vm.openFolder() } }),
            ("Refresh", "arrow.clockwise", { Task { await vm.refreshFolder() } }),
            ("Toggle Status Bar", "rectangle.bottomthird.inset.filled", { vm.showStatusBar.toggle(); vm.persistStatusBarVisibility() }),
            ("Toggle Preview Pane", "sidebar.right", { vm.togglePreviewPane() }),
            ("New Smart Folder", "folder.badge.gearshape", { vm.editingSmartFolder = nil; vm.showSmartFolderEditor = true }),
            ("Settings", "gearshape", { vm.openSettings() }),
            ("Statistics", "chart.bar", { vm.statisticsOpen = true }),
            vm.isSimilarImagesPageActive
                ? ("Show Browser", "square.grid.2x2", { vm.leaveSimilarImagesPage() })
                : ("Similar Images", "square.on.square", { vm.showSimilarImagesPage() }),
        ]

        // Timeline and Map pages (Views/Timeline, Views/Map).
        actions.append(vm.isTimelinePageActive
            ? ("Show Browser", "square.grid.2x2", { vm.leaveMapTimelinePage() })
            : ("Timeline", "calendar.day.timeline.left", { vm.showTimelinePage() }))
        if !vm.isMapPageActive {
            actions.append(("Map", "map", { vm.showMapPage() }))
        }

        // Viewing tools (Views/Compare, Views/Viewing).
        if vm.canCompareImages, !vm.isComparePageActive {
            actions.append(("Compare Images", "rectangle.split.2x1", { vm.compareImagesCommand() }))
        }
        if vm.canStartSlideshow {
            actions.append(("Start Slideshow", "play.rectangle", { vm.startSlideshow() }))
        }

        // Non-destructive image editor (Views/Editor).
        if vm.canEditImage {
            actions.append(("Edit Image…", "slider.horizontal.below.rectangle", { vm.openEditImageForTarget() }))
        }
        if vm.canSaveEditedCopy {
            actions.append(("Save Edited Copy…", "doc.badge.plus", { vm.saveEditedCopyForTarget() }))
        }

        // Version stacks and suggested tags (Views/Stacks).
        if vm.stackScope != nil {
            actions.append((vm.isStackingEnabled ? "Turn Off Stack Variants" : "Stack Variants", "square.stack.3d.up", { vm.toggleStackingForCurrentListing() }))
        }
        if vm.canStackSelection {
            actions.append(("Stack Selected", "square.stack.3d.up.fill", { vm.stackSelection() }))
        }
        if vm.canApplySuggestedTags {
            actions.append(("Apply Suggested Tags…", "tag.circle", { vm.openApplySuggestedTags() }))
        }

        // Ingest inbox (only with a watched folder).
        if IngestController.shared.hasSources {
            actions += [
                ("Show Inbox", "tray.and.arrow.down", { vm.openInbox() }),
                ("Mark Inbox as Seen", "checkmark.circle", { vm.markInboxSeen() }),
            ]
        }

        // Export suite (selection, else the listing).
        if vm.canExport {
            actions += [
                ("Export…", "square.and.arrow.up", { vm.openExportSheet() }),
                ("Export for Sharing (Strip AI Metadata)…", "lock.shield", { vm.openExportForSharing() }),
                ("Export Contact Sheet…", "rectangle.grid.3x2", { vm.openContactSheet() }),
            ]
        }

        // Video tools (the selected video).
        if vm.canSaveMiddleFrame {
            actions.append(("Save Middle Frame", "photo.badge.arrow.down", { vm.saveMiddleFramesForTarget() }))
        }
        if vm.canTrimVideo {
            actions.append(("Trim & Export Clip…", "timeline.selection", { vm.openTrimForTarget() }))
        }

        // Prompt workflows (Views/Prompts).
        actions += [
            ("Prompt Builder…", "hammer", { vm.openPromptBuilderForTarget() }),
            ("Prompt Statistics…", "chart.bar.xaxis", { vm.openPromptStatistics() }),
        ]
        if vm.canShowPromptLineage {
            actions.append(("Show Prompt Lineage", "point.topleft.down.to.point.bottomright.curvepath", { vm.showPromptLineage() }))
        }
        if vm.promptActionTargets.count == 1, vm.canSendToGenerator(.comfyUI, item: vm.promptActionTarget) {
            actions.append(("Re-run in ComfyUI…", "point.3.connected.trianglepath.dotted", { vm.sendTargetToGenerator(.comfyUI) }))
        }
        if vm.promptActionTargets.count == 1, vm.canSendToGenerator(.a1111, item: vm.promptActionTarget) {
            actions.append(("Send to A1111 / Forge…", "paperplane", { vm.sendTargetToGenerator(.a1111) }))
        }

        for (name, icon, action) in actions where q.isEmpty || name.lowercased().contains(q) {
            items.append(.action(name: name, icon: icon, action: action))
        }

        // Sort options
        let sortOptions: [(String, SortConfig)] = [
            ("Sort by Type (A-Z)", SortConfig(field: .type, direction: .asc)),
            ("Sort by Name (A-Z)", SortConfig(field: .name, direction: .asc)),
            ("Sort by Rating", SortConfig(field: .rating, direction: .asc)),
        ]

        for (name, config) in sortOptions where q.isEmpty || name.lowercased().contains(q) {
            items.append(.action(name: name, icon: "arrow.up.arrow.down") {
                vm.sortConfig = config
                vm.persistSortConfig()
            })
        }

        return Array(items.prefix(20))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.appMuted)
                TextField("Search folders, files, tags, actions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.appIcon(16))
                    .foregroundStyle(Color.appPrimaryText)
                    .focused($isFocused)
                    .onKeyPress(.escape) {
                        closePalette()
                        return .handled
                    }
                    .onSubmit(activateHighlighted)
                    .accessibilityLabel("Command palette search")

                if isSearchingFiles {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Searching files")
                }

                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.appMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, AppSpacing.xxs)
                    .background(Color.appSurface)
                    .cornerRadius(AppRadius.xs)
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, 14)
            .background(Color.appSurface.opacity(0.8))

            Divider().background(Color.appBorder)

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        let flat = flatItems
                        ForEach(Array(sections.enumerated()), id: \.offset) { sectionIndex, section in
                            Text(section.title.uppercased())
                                .font(.appMicro)
                                .tracking(0.6)
                                .foregroundStyle(Color.appMuted)
                                .padding(.horizontal, 10)
                                .padding(.top, sectionIndex == 0 ? AppSpacing.xxs : AppSpacing.md)
                                .padding(.bottom, AppSpacing.xxs)
                                .accessibilityAddTraits(.isHeader)

                            let offset = sections[..<sectionIndex].reduce(0) { $0 + $1.items.count }
                            ForEach(Array(section.items.enumerated()), id: \.offset) { itemIndex, item in
                                let index = offset + itemIndex
                                CommandPaletteRow(item: item, isHighlighted: index == highlightedIndex) {
                                    handleSelection(item)
                                }
                                .id(index)
                                .onHover { hovering in
                                    if hovering { highlightedIndex = index }
                                }
                            }
                        }
                        if flat.isEmpty {
                            Text(isSearchingFiles ? "Searching…" : "No matches")
                                .font(.appCallout)
                                .foregroundStyle(Color.appMuted)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, AppSpacing.xl)
                        }
                    }
                    .padding(AppSpacing.md)
                }
                .frame(maxHeight: 420)
                .onChange(of: highlightedIndex) { _, index in
                    proxy.scrollTo(index)
                }
            }
        }
        .frame(width: 560)
        .background(Color.appBackground.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.appAccent.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: Color.appShadowColor.opacity(0.8), radius: 24, y: 8)
        .background {
            // A real cancel-action button so Esc closes the palette even when the
            // search field (not a SwiftUI view) is first responder.
            Button("Close Command Palette", action: closePalette)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .background {
            // Arrow keys move the highlight across every section. Real buttons
            // take the key equivalent before the search field's editor does.
            Group {
                Button("Previous Result") { moveHighlight(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("Next Result") { moveHighlight(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onChange(of: query) { _, _ in highlightedIndex = 0 }
        .task(id: query) { await searchFiles(for: query) }
        .onAppear { isFocused = true }
        .onExitCommand(perform: closePalette)
    }

    private func moveHighlight(by delta: Int) {
        let count = flatItems.count
        guard count > 0 else { return }
        highlightedIndex = min(max(highlightedIndex + delta, 0), count - 1)
    }

    private func activateHighlighted() {
        let items = flatItems
        guard items.indices.contains(highlightedIndex) else { return }
        handleSelection(items[highlightedIndex])
    }

    /// Debounced; `.task(id:)` cancels the previous query's task, and a
    /// cancelled task never writes its (stale) hits.
    private func searchFiles(for text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fileHits = []
            isSearchingFiles = false
            return
        }
        isSearchingFiles = true
        do {
            try await Task.sleep(for: Self.fileSearchDebounce)
        } catch {
            return
        }
        let hits = await vm.paletteFileMatches(trimmed, limit: 20)
        guard !Task.isCancelled else { return }
        fileHits = hits
        isSearchingFiles = false
        let count = flatItems.count
        if highlightedIndex >= count { highlightedIndex = max(0, count - 1) }
    }

    private func closePalette() {
        vm.commandPaletteOpen = false
    }

    private func handleSelection(_ item: CommandPaletteItem) {
        vm.commandPaletteOpen = false

        switch item {
        case .folder(let folder):
            Task { await vm.selectFolder(folder.url) }
        case .smartFolder(let sf):
            vm.activateSmartFolder(sf)
        case .tag(let tag):
            // A tag filters the browser, so the Similar Images page makes way.
            if vm.similarPage.handle(.tagFilterChanged) == .leftPage, vm.filterByTagID == tag.id { return }
            vm.filterByTagID = vm.filterByTagID == tag.id ? nil : tag.id
        case .action(_, _, let action):
            action()
        case .help(_, _, let action):
            // Help and the tour are sheets; let the palette's overlay go first.
            DispatchQueue.main.async { action() }
        case .file(let hit):
            vm.revealLibraryHit(hit)
        }
    }
}

enum CommandPaletteItem {
    case folder(SidebarFolderItem)
    case smartFolder(SmartFolder)
    case tag(FileTag)
    case action(name: String, icon: String, action: () -> Void)
    /// "Help: …" — opens Help at a topic (or the tour, tips, shortcuts).
    case help(name: String, icon: String, action: () -> Void)
    case file(LibrarySearchHit)

    var sectionTitle: String {
        switch self {
        case .folder: return "Folders"
        case .smartFolder: return "Smart Folders"
        case .tag: return "Tags"
        case .action: return "Actions"
        case .help: return "Help"
        case .file: return "Files"
        }
    }

    var displayName: String {
        switch self {
        case .file(let hit): return hit.fileName
        case .folder(let f): return f.name
        case .smartFolder(let sf): return sf.name
        case .tag(let t): return t.name
        case .action(let name, _, _): return name
        case .help(let name, _, _): return name
        }
    }
}

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName)
                        .font(.appBody)
                        .foregroundStyle(Color.appPrimaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if case .file(let hit) = item {
                        Text((hit.folderPath as NSString).abbreviatingWithTildeInPath)
                            .font(.appFootnote)
                            .foregroundStyle(Color.appMuted)
                            .lineLimit(1)
                            .truncationMode(.head)
                        if !hit.snippet.isEmpty {
                            Text(PaletteSnippet.attributed(hit.snippet))
                                .font(.appCaption)
                                .foregroundStyle(Color.appMuted)
                                .lineLimit(2)
                        }
                    }
                }

                Spacer(minLength: AppSpacing.md)

                categoryLabel
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(isHighlighted ? Color.appSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityText: String {
        switch item {
        case .file(let hit):
            let snippet = hit.snippet.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
            return "File \(hit.fileName), in \((hit.folderPath as NSString).lastPathComponent). \(snippet)"
        case .help(let name, _, _):
            return name
        default:
            return "\(item.sectionTitle.dropLast()) \(item.displayName)"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item {
        case .folder:
            Image(systemName: "folder.fill")
                .font(.appBody)
                .foregroundStyle(Color.appAccent)
                .frame(width: 20)
        case .smartFolder:
            Image(systemName: "folder.badge.gearshape")
                .font(.appBody)
                .foregroundStyle(Color.appAccent)
                .frame(width: 20)
        case .tag(let tag):
            Circle()
                .fill(tag.color)
                .frame(width: 12, height: 12)
                .frame(width: 20)
        case .action(_, let iconName, _):
            Image(systemName: iconName)
                .font(.appBody)
                .foregroundStyle(Color.appMuted)
                .frame(width: 20)
        case .help(_, let iconName, _):
            Image(systemName: iconName)
                .font(.appBody)
                .foregroundStyle(Color.appAccent)
                .frame(width: 20)
        case .file(let hit):
            PaletteThumbnail(path: hit.path)
        }
    }

    @ViewBuilder
    private var categoryLabel: some View {
        let label: String = {
            switch item {
            case .folder: return "Folder"
            case .smartFolder: return "Smart Folder"
            case .tag: return "Tag"
            case .action: return "Action"
            case .help: return "Help"
            case .file: return "File"
            }
        }()

        Text(label)
            .font(.appIcon(10, weight: .medium))
            .foregroundStyle(Color.appMuted)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xxs)
            .background(Color.appSurface)
            .cornerRadius(AppRadius.xs)
    }
}

/// Small async thumbnail for a file hit.
private struct PaletteThumbnail: View {
    let path: String
    private let size: CGFloat = 36

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .fill(Color.appSurface)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "doc.text.image")
                    .font(.appIcon(14))
                    .foregroundStyle(Color.appMuted)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
        .accessibilityHidden(true)
        .task(id: path) {
            let url = URL(fileURLWithPath: path)
            if let cached = ThumbnailService.shared.cachedThumbnail(for: url, size: size * 2) {
                image = cached
                return
            }
            let loaded = await ThumbnailService.shared.thumbnail(for: url, size: size * 2)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// Turns a «»-marked snippet into styled text with the matches highlighted.
enum PaletteSnippet {
    static func attributed(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var remaining = Substring(snippet)
        while let open = remaining.firstIndex(of: "«") {
            result += AttributedString(String(remaining[..<open]))
            let afterOpen = remaining.index(after: open)
            guard let close = remaining[afterOpen...].firstIndex(of: "»") else {
                remaining = remaining[afterOpen...]
                break
            }
            var match = AttributedString(String(remaining[afterOpen..<close]))
            match.foregroundColor = .appPrimaryText
            match.backgroundColor = Color.appAccent.opacity(0.22)
            match.inlinePresentationIntent = .stronglyEmphasized
            result += match
            remaining = remaining[remaining.index(after: close)...]
        }
        result += AttributedString(String(remaining))
        return result
    }
}

/// Matching for the palette's "Help: …" rows: by topic title, chip, keywords and
/// the titles of the tips that point at the topic (not the full text, which would
/// flood the palette).
enum HelpPaletteMatch {
    static func matches(_ query: String, entry: HelpEntry) -> Bool {
        let tipTitles = OnboardingTip.allCases.filter { $0.helpEntryID == entry.id }.map(\.title)
        return matches(query, texts: [entry.title, entry.label, entry.section.title] + entry.keywords + tipTitles)
    }

    static func matches(_ query: String, texts: [String]) -> Bool {
        let words = HelpSearch.tokens(query)
        guard !words.isEmpty else { return false }
        let text = HelpSearch.normalized(texts.joined(separator: " "))
        return words.allSatisfy { text.contains($0) }
    }
}
