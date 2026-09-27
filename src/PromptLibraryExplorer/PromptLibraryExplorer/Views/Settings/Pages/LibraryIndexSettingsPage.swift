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
