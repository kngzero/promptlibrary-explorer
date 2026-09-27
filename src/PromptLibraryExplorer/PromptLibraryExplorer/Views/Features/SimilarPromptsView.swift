import SwiftUI

/// Finds clusters of near-identical prompts in the current listing (vm.duplicatesOpen).
struct SimilarPromptsView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @AppStorage("similarPrompts.threshold") private var threshold: Double = 0.8
    @State private var hasSearched = false
    @State private var newCollectionPaths: [String]?
    @State private var newCollectionName = ""

    private var clusters: [[String]] { vm.duplicateClusters }

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Similar Prompts",
                subtitle: "Groups files in this listing whose prompts are nearly the same",
                systemImage: "square.on.square.dashed",
                onClose: close
            )

            controls
                .padding(.horizontal, AppSpacing.xl)
                .padding(.vertical, AppSpacing.lg)

            Divider().background(Color.appBorder)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)

            FeatureSheetFooter {
                Text(summaryText)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 640)
        .background(Color.appBackground)
        .onAppear {
            hasSearched = !clusters.isEmpty
        }
        .alert(
            "New Collection",
            isPresented: Binding(
                get: { newCollectionPaths != nil },
                set: { if !$0 { newCollectionPaths = nil } }
            )
        ) {
            TextField("Collection name", text: $newCollectionName)
            Button("Create") {
                if let paths = newCollectionPaths { createCollection(named: newCollectionName, paths: paths) }
                newCollectionPaths = nil
            }
            Button("Cancel", role: .cancel) { newCollectionPaths = nil }
        } message: {
            Text("Create a collection with the files in this group.")
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: AppSpacing.lg) {
            Text("Similarity")
                .font(.appCalloutEmphasis)
                .foregroundStyle(Color.appMuted)

            Slider(value: $threshold, in: 0.6...0.95, step: 0.01)
                .tint(Color.appAccent)
                .frame(maxWidth: 280)

            Text("\(Int((threshold * 100).rounded()))%")
                .font(.appMono)
                .foregroundStyle(Color.appPrimaryText)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

            Text(threshold >= 0.9 ? "near-identical" : (threshold >= 0.75 ? "very similar" : "loosely similar"))
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)

            Spacer()

            if vm.isFindingDuplicates {
                ProgressView().controlSize(.small)
            }

            Button {
                hasSearched = true
                vm.findDuplicatePrompts(threshold: threshold)
            } label: {
                Label("Find Similar", systemImage: "sparkle.magnifyingglass")
                    .font(.appCalloutEmphasis)
            }
            .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
            .disabled(vm.isFindingDuplicates)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.isFindingDuplicates && clusters.isEmpty {
            VStack(spacing: AppSpacing.md) {
                ProgressView().controlSize(.small)
                Text("Comparing prompts…")
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if clusters.isEmpty {
            FeatureEmptyState(
                systemImage: hasSearched ? "checkmark.seal" : "square.on.square.dashed",
                title: hasSearched ? "No similar prompts found" : "Find files with near-duplicate prompts",
                message: hasSearched
                    ? "Nothing in this listing is above \(Int((threshold * 100).rounded()))% similar. Lower the threshold to find looser matches."
                    : "Choose a similarity threshold and click Find Similar. Only files in the current listing are compared."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.lg) {
                    ForEach(Array(clusters.enumerated()), id: \.offset) { index, cluster in
                        clusterCard(index: index, paths: cluster)
                    }
                }
                .padding(AppSpacing.xl)
            }
            .opacity(vm.isFindingDuplicates ? 0.5 : 1)
        }
    }

    private func clusterCard(index: Int, paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.md) {
                Text("Group \(index + 1)")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appPrimaryText)
                Text("\(paths.count) files")
                    .font(.appMicro)
                    .foregroundStyle(Color.appOnAccent)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xxs)
                    .background(Capsule().fill(Color.appAccent))

                Spacer()

                Button {
                    compare(paths)
                } label: {
                    Label("Compare", systemImage: "arrow.left.arrow.right")
                        .font(.appCaption)
                }
                .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
                .help("Compare the first two prompts in this group")

                Button {
                    selectInGrid(paths)
                } label: {
                    Label("Select in Grid", systemImage: "checkmark.circle")
                        .font(.appCaption)
                }
                .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))

                Menu {
                    if !vm.collections.isEmpty {
                        CollectionMenuItems(vm: vm) { collection in
                            add(paths, to: collection)
                        }
                        Divider()
                    }
                    Button("New Collection…") {
                        newCollectionName = "Similar Prompts \(index + 1)"
                        newCollectionPaths = paths
                    }
                } label: {
                    Label("Add to Collection", systemImage: "rectangle.stack.badge.plus")
                        .font(.appCaption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Color.appMuted)
            }

            VStack(spacing: AppSpacing.xs) {
                ForEach(paths, id: \.self) { path in
                    HStack(alignment: .top, spacing: AppSpacing.md) {
                        FeatureThumbnail(path: path, size: 40)
                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.appCalloutEmphasis)
                                .foregroundStyle(Color.appPrimaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(FeatureText.truncated(vm.promptTextByPath[path] ?? "", limit: 200))
                                .font(.appCaption)
                                .foregroundStyle(Color.appMuted)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(AppSpacing.xs)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { selectInGrid([path]) }
                }
            }
        }
        .padding(AppSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private var summaryText: String {
        guard !clusters.isEmpty else { return "Compares prompts in the current listing" }
        let files = clusters.reduce(0) { $0 + $1.count }
        return "\(clusters.count) group\(clusters.count == 1 ? "" : "s") · \(files) files"
    }

    // MARK: - Actions

    private func compare(_ paths: [String]) {
        close()
        // The diff is a sheet on the same window; present it once this one is gone.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            vm.compareCluster(paths)
        }
    }

    /// Selects every listed path in the grid (first becomes primary).
    private func selectInGrid(_ paths: [String]) {
        let items = vm.processedFolderContents
        let wanted = Set(paths)
        let indices = items.indices.filter { wanted.contains(items[$0].path) }
        guard let first = indices.first else {
            vm.showToast("These files aren't in the current listing", type: .info)
            return
        }
        // Build the set from the rest, then ⌘-add the first last so it ends up
        // as the primary selection shown in the detail panel.
        let rest = Array(indices.dropFirst())
        if let head = rest.first {
            vm.selectItem(at: head)
            for index in rest.dropFirst() {
                vm.selectItem(at: index, modifiers: .command)
            }
            vm.selectItem(at: first, modifiers: .command)
        } else {
            vm.selectItem(at: first)
        }
        close()
    }

    private func add(_ paths: [String], to collection: FileCollection) {
        CollectionService.shared.add(paths: paths, to: collection.id)
        vm.collections = CollectionService.shared.all()
        vm.showToast("Added \(paths.count) file\(paths.count == 1 ? "" : "s") to \"\(collection.name)\"", type: .success)
        if vm.activeCollectionID == collection.id {
            Task { await vm.reloadCollectionContents() }
        }
    }

    private func createCollection(named name: String, paths: [String]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = CollectionService.shared.create(name: trimmed.isEmpty ? "Similar Prompts" : trimmed, paths: paths)
        vm.collections = CollectionService.shared.all()
        vm.showToast("Created \"\(collection.name)\" with \(paths.count) files", type: .success)
    }

    private func close() {
        vm.duplicatesOpen = false
        dismiss()
    }
}
