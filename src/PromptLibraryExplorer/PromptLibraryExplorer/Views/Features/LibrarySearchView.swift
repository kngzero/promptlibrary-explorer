import SwiftUI

/// Full-library prompt search over the LibraryIndexService (vm.librarySearchOpen).
struct LibrarySearchView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @FocusState private var searchFocused: Bool
    @State private var highlightedID: String?
    @State private var hoveredID: String?
    @State private var stats: LibraryIndexStats?

    private var results: [LibrarySearchHit] { vm.librarySearchResults }
    private var trimmedQuery: String {
        vm.librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        @Bindable var vm = vm

        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Search Library",
                subtitle: vm.explorerRootPath.map { "Prompts in \($0.lastPathComponent) and its subfolders" },
                systemImage: "text.magnifyingglass",
                onClose: close
            )

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                FeatureSearchField(
                    placeholder: "Search prompts across the library…",
                    text: $vm.librarySearchQuery,
                    isFocused: $searchFocused,
                    onSubmit: openHighlighted
                )
                .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }

                syntaxHint
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.lg)

            Divider().background(Color.appBorder)

            resultsArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)

            footer
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 620)
        .background(Color.appBackground)
        .onAppear {
            searchFocused = true
            if !trimmedQuery.isEmpty { vm.runLibrarySearch() }
        }
        .onChange(of: vm.librarySearchQuery) { _, _ in
            vm.runLibrarySearch()
        }
        .onChange(of: vm.librarySearchResults) { _, newResults in
            if let highlightedID, newResults.contains(where: { $0.id == highlightedID }) { return }
            highlightedID = newResults.first?.id
        }
        .task(id: vm.isLibraryIndexing) {
            stats = await LibraryIndexService.shared.stats(under: vm.explorerRootPath)
        }
    }

    // MARK: - Pieces

    private var syntaxHint: some View {
        HStack(spacing: AppSpacing.lg) {
            hintToken("words", "all must match")
            hintToken("\"a phrase\"", "exact phrase")
            hintToken("-word", "exclude")
            hintToken("pre*", "prefix")
            Spacer()
            Text("↑↓ to move · ↩ to open")
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)
        }
    }

    private func hintToken(_ token: String, _ meaning: String) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Text(token)
                .font(.appMono)
                .foregroundStyle(Color.appPrimaryText)
                .padding(.horizontal, AppSpacing.xs)
                .padding(.vertical, AppSpacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous)
                        .fill(Color.appElevatedSurface)
                )
            Text(meaning)
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if trimmedQuery.isEmpty {
            FeatureEmptyState(
                systemImage: "text.magnifyingglass",
                title: "Search every prompt in the library",
                message: (stats?.fileCount ?? 0) == 0 && !vm.isLibraryIndexing
                    ? "The library hasn't been indexed yet. Choose Reindex below to build the index."
                    : "Type words from a prompt, a model name or a seed."
            )
        } else if vm.isLibrarySearching && results.isEmpty {
            VStack(spacing: AppSpacing.md) {
                ProgressView().controlSize(.small)
                Text("Searching…")
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            FeatureEmptyState(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: vm.isLibraryIndexing
                    ? "Indexing is still running — more results may appear when it finishes."
                    : "Try fewer words, a prefix like port*, or remove exclusions."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: AppSpacing.xxs) {
                        ForEach(results) { hit in
                            resultRow(hit)
                                .id(hit.id)
                        }
                    }
                    .padding(AppSpacing.md)
                }
                .onChange(of: highlightedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(id)
                    }
                }
            }
        }
    }

    private func resultRow(_ hit: LibrarySearchHit) -> some View {
        let isHighlighted = highlightedID == hit.id
        return HStack(alignment: .top, spacing: AppSpacing.lg) {
            FeatureThumbnail(path: hit.path, size: 48)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                HStack(spacing: AppSpacing.sm) {
                    Text(hit.fileName)
                        .font(.appCalloutEmphasis)
                        .foregroundStyle(Color.appPrimaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: AppSpacing.md)
                    Text(FeatureText.relativeFolder(hit.folderPath, root: vm.explorerRootPath))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if !hit.snippet.isEmpty {
                    Text(FeatureText.highlightedSnippet(hit.snippet))
                        .font(.appCallout)
                        .foregroundStyle(Color.appPrimaryText.opacity(0.82))
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(FeatureRowBackground(isSelected: isHighlighted, isHovered: hoveredID == hit.id))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredID = hit.id } else if hoveredID == hit.id { hoveredID = nil }
        }
        .onTapGesture(count: 2) { open(hit) }
        .onTapGesture { highlightedID = hit.id }
        .contextMenu {
            Button("Reveal in Library") { open(hit) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)])
            }
            Button("Copy Path") {
                ClipboardService.copyString(hit.path)
                vm.showToast("Path copied", type: .success)
            }
        }
    }

    private var footer: some View {
        FeatureSheetFooter {
            if vm.isLibraryIndexing {
                let progress = vm.libraryIndexProgress
                ProgressView(
                    value: Double(progress?.done ?? 0),
                    total: Double(max(progress?.total ?? 0, 1))
                )
                .progressViewStyle(.linear)
                .tint(Color.appAccent)
                .frame(width: 160)
                Text(indexProgressText(progress))
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .monospacedDigit()
            } else {
                Image(systemName: "externaldrive")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                Text(statsText)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }

            Spacer()

            if !results.isEmpty {
                Text("\(results.count)\(results.count >= 200 ? "+" : "") result\(results.count == 1 ? "" : "s")")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }

            if vm.isLibraryIndexing {
                Button("Stop Indexing") { vm.cancelLibraryIndex() }
            } else {
                Button("Reindex") { vm.reindexLibrary() }
                    .disabled(vm.explorerRootPath == nil)
                    .help("Rebuild the prompt index for this library")
            }

            Button("Open") { openHighlighted() }
                .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                .disabled(highlightedHit == nil)
        }
    }

    private var statsText: String {
        guard let stats else { return "Loading index…" }
        let files = "\(stats.fileCount.formatted()) file\(stats.fileCount == 1 ? "" : "s") indexed"
        guard let last = stats.lastIndexed else { return stats.fileCount == 0 ? "Not indexed yet" : files }
        return "\(files) · updated \(last.formatted(.relative(presentation: .named)))"
    }

    private func indexProgressText(_ progress: (done: Int, total: Int)?) -> String {
        guard let progress, progress.total > 0 else { return "Scanning library…" }
        return "Indexing \(progress.done.formatted()) of \(progress.total.formatted())"
    }

    // MARK: - Actions

    private var highlightedHit: LibrarySearchHit? {
        guard let highlightedID else { return nil }
        return results.first { $0.id == highlightedID }
    }

    private func moveHighlight(by offset: Int) {
        guard !results.isEmpty else { return }
        let current = highlightedID.flatMap { id in results.firstIndex { $0.id == id } }
        let next: Int
        if let current {
            next = min(max(current + offset, 0), results.count - 1)
        } else {
            next = offset > 0 ? 0 : results.count - 1
        }
        highlightedID = results[next].id
    }

    private func openHighlighted() {
        guard let hit = highlightedHit ?? results.first else { return }
        open(hit)
    }

    private func open(_ hit: LibrarySearchHit) {
        vm.revealLibraryHit(hit)
        close()
    }

    private func close() {
        vm.librarySearchOpen = false
        dismiss()
    }
}
