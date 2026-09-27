import SwiftUI

/// Settings page for the persistent library search index.
struct LibraryIndexSettingsPage: View {
    @Environment(ExplorerViewModel.self) private var vm

    @State private var stats: LibraryIndexStats?
    @State private var isLoadingStats = false
    @State private var isResetting = false
    @State private var confirmReset = false
    @State private var resultMessage: String?

    private var root: URL? { vm.explorerRootPath }

    var body: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                Label("Search Index", systemImage: "text.magnifyingglass")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appAccent)

                Spacer(minLength: 0)

                if isLoadingStats {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await refreshStats() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.appCalloutEmphasis)
                    }
                    .buttonStyle(AppIconButtonStyle(width: 24, height: 24, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                    .help("Refresh index statistics")
                    .accessibilityLabel("Refresh index statistics")
                }
            }

            VStack(spacing: AppSpacing.md) {
                SettingsStatRow(
                    label: "Library root",
                    detail: root.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "open a folder to index it",
                    value: root?.lastPathComponent ?? "—"
                )
                SettingsStatRow(
                    label: "Indexed files",
                    detail: "under the current root",
                    value: stats.map { $0.fileCount == 1 ? "1 file" : "\($0.fileCount) files" } ?? "—"
                )
                SettingsStatRow(
                    label: "Last indexed",
                    detail: "re-indexes automatically after 24 hours",
                    value: lastIndexedLabel
                )
            }

            if vm.isLibraryIndexing {
                progressView
            }

            SettingsFootnote("The index stores prompt text and generation parameters so library search, the command palette and grouping work across every subfolder without re-reading files.")

            HStack(spacing: AppSpacing.lg) {
                SettingsFilledButton(
                    title: vm.isLibraryIndexing ? "Indexing…" : "Reindex Now",
                    isBusy: vm.isLibraryIndexing,
                    isEnabled: root != nil && !isResetting,
                    action: { vm.reindexLibrary() }
                )
                .accessibilityHint("Rebuilds the search index for the current library root")

                SettingsFilledButton(
                    title: "Reset Index",
                    tint: Color.appError,
                    isBusy: isResetting,
                    isEnabled: !vm.isLibraryIndexing,
                    action: { confirmReset = true }
                )
                .accessibilityHint("Deletes the whole search index")
            }
        }
        .task { await refreshStats() }
        .onChange(of: vm.isLibraryIndexing) { _, indexing in
            if !indexing { Task { await refreshStats() } }
        }
        .alert("Reset the search index?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                Task { await resetIndex() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every indexed prompt is removed for all libraries. Your files are untouched; library search stays empty until you reindex.")
        }

        if let resultMessage {
            SettingsResultBanner(message: resultMessage, tone: .success)
        }

        VisualIndexSettingsSection()

        // OCR + classification (Views/Stacks); follows the visual index's schedule.
        ImageAnalysisSettingsSection()
    }

    @ViewBuilder
    private var progressView: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if let progress = vm.libraryIndexProgress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .tint(Color.appAccent)
                Text("\(progress.done) of \(progress.total) files")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .monospacedDigit()
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.appAccent)
                Text("Scanning the library…")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Indexing progress")
    }

    private var lastIndexedLabel: String {
        guard let date = stats?.lastIndexed else { return stats == nil ? "—" : "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func refreshStats() async {
        isLoadingStats = true
        defer { isLoadingStats = false }
        stats = await LibraryIndexService.shared.stats(under: root)
    }

    private func resetIndex() async {
        isResetting = true
        defer { isResetting = false }
        vm.cancelLibraryIndex()
        await LibraryIndexService.shared.reset()
        await refreshStats()
        resultMessage = "Search index cleared. Choose Reindex Now to rebuild it."
    }
}

// MARK: - Visual index

/// The visual index (similar images, More Like This, colour search): status, counts
/// and the same Pause / Resume / Stop controls as the status-bar popover.
private struct VisualIndexSettingsSection: View {
    @Environment(ExplorerViewModel.self) private var vm

    @State private var stats: (indexed: Int, total: Int?)?
    @State private var confirmReset = false
    @State private var isResetting = false
    @State private var resultMessage: String?

    private var controller: VisualIndexController { .shared }
    private var root: URL? { vm.explorerRootPath }

    var body: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                Label("Visual Index", systemImage: "photo.stack")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appAccent)
                Spacer(minLength: 0)
                Button {
                    Task { await refreshStats() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.appCalloutEmphasis)
                }
                .buttonStyle(AppIconButtonStyle(width: 24, height: 24, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                .help("Refresh visual index statistics")
                .accessibilityLabel("Refresh visual index statistics")
            }

            VStack(spacing: AppSpacing.md) {
                SettingsStatRow(label: "Status", detail: statusDetail, value: statusLabel)
                SettingsStatRow(label: "Indexed files", detail: "images, videos, boards under the root", value: indexedLabel)
                SettingsStatRow(label: "Last completed", detail: "updates automatically as files change", value: lastCompletedLabel)
            }

            if controller.state == .indexing || controller.state == .paused {
                progressView
            }

            SettingsToggleRow(
                title: "Index automatically",
                detail: "Builds visual signatures in the background, at low priority, whenever a library opens. Turning this off is the same as Stop.",
                isOn: Binding(
                    get: { controller.isEnabled },
                    set: { enabled in
                        controller.isEnabled = enabled
                        if enabled, let root { controller.start(root: root) }
                    }
                )
            )

            SettingsFootnote("Signatures (content hash, perceptual hash, Vision feature print and dominant colours) power Library ▸ Similar Images, More Like This and colour search. They stay on this Mac and your files are never modified.")

            HStack(spacing: AppSpacing.lg) {
                switch controller.state {
                case .indexing:
                    SettingsFilledButton(title: "Pause", action: { controller.pause() })
                        .accessibilityHint("Pauses visual indexing; files already indexed are kept")
                case .paused:
                    SettingsFilledButton(title: "Resume", action: { controller.resume() })
                        .accessibilityHint("Continues visual indexing where it stopped")
                default:
                    SettingsFilledButton(
                        title: "Re-index",
                        isEnabled: root != nil && !isResetting,
                        action: { if let root { controller.reindex(root: root) } }
                    )
                    .accessibilityHint("Recomputes the visual signature of every file under the current library root")
                }

                if controller.state == .indexing || controller.state == .paused {
                    Button("Stop") { controller.stop() }
                        .buttonStyle(AppLabeledButtonStyle(height: 38, horizontalPadding: AppSpacing.xl, cornerRadius: AppRadius.lg))
                        .font(.appTitle)
                        .help("Stop visual indexing and turn off automatic indexing")
                        .accessibilityHint("Stops visual indexing and turns off automatic indexing until you turn it back on")
                }

                SettingsFilledButton(
                    title: "Reset Visual Index",
                    tint: Color.appError,
                    isBusy: isResetting,
                    isEnabled: !isResetting,
                    action: { confirmReset = true }
                )
                .accessibilityHint("Deletes every stored visual signature")
            }
        }
        .task { await refreshStats() }
        .onChange(of: controller.state) { _, state in
            if state != .indexing { Task { await refreshStats() } }
        }
        .alert("Reset the visual index?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                Task { await resetIndex() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every stored visual signature is removed for all libraries. Your files are untouched; similar-image and colour search stay empty until the index is rebuilt.")
        }

        if let resultMessage {
            SettingsResultBanner(message: resultMessage, tone: .success)
        }
    }

    @ViewBuilder
    private var progressView: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if let progress = controller.progress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .tint(Color.appAccent)
                HStack(spacing: AppSpacing.md) {
                    Text("\(progress.done.formatted()) of \(progress.total.formatted()) files")
                        .monospacedDigit()
                    if let name = controller.currentItemName, controller.state == .indexing {
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.appAccent)
                Text("Scanning the library…")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Visual indexing progress")
    }

    private var statusLabel: String {
        switch controller.state {
        case .idle: return "Waiting"
        case .indexing: return "Indexing"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .completed: return "Up to date"
        }
    }

    private var statusDetail: String {
        switch controller.state {
        case .idle: return "starts when a library opens"
        case .indexing: return "running in the background"
        case .paused: return "finished files are kept"
        case .stopped: return "automatic indexing is off"
        case .completed: return "new and changed files are picked up"
        }
    }

    private var indexedLabel: String {
        guard let stats else { return "—" }
        if let total = stats.total, total > 0 { return "\(stats.indexed.formatted()) / \(total.formatted())" }
        return stats.indexed == 1 ? "1 file" : "\(stats.indexed.formatted()) files"
    }

    private var lastCompletedLabel: String {
        guard let date = controller.lastCompleted else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func refreshStats() async {
        stats = await VisualIndexService.shared.stats(under: root)
    }

    private func resetIndex() async {
        isResetting = true
        defer { isResetting = false }
        await controller.resetIndex()
        await refreshStats()
        resultMessage = "Visual index cleared. It rebuilds the next time a library opens, or choose Re-index."
    }
}
