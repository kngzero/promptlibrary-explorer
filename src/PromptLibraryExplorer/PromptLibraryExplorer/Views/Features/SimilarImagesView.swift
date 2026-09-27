import AppKit
import SwiftUI

/// Library ▸ Find Similar Images… (vm.similarImagesOpen).
///
/// HARD RULE (user decision): groups are for inspection only. No file is
/// marked, pre-selected, highlighted as "best" or offered for removal —
/// higher-resolution copies are often upscales of a master. The only actions
/// are those in `SimilarGroupAction` (compare, select, collect, reveal, lightbox).
struct SimilarImagesView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @AppStorage("similarImages.strictness") private var strictness: Double = 0.85
    @AppStorage("similarImages.includeVideos") private var includeVideos = true
    @State private var newCollectionPaths: [String]?
    @State private var newCollectionName = ""

    private var model: SimilarImagesModel { vm.similarImages }
    private var indexController: VisualIndexController { VisualIndexController.shared }

    var body: some View {
        @Bindable var vm = vm

        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Similar Images",
                subtitle: "Groups exact copies and near-duplicates. Every file is kept — this is for looking, not cleaning up.",
                systemImage: "square.on.square",
                onClose: close
            )

            controls
                .padding(.horizontal, AppSpacing.xl)
                .padding(.vertical, AppSpacing.lg)

            if indexController.state == .indexing, let progress = indexController.progress, progress.total > 0 {
                indexingBanner(progress)
            }

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
        .frame(minWidth: 760, idealWidth: 880, minHeight: 540, idealHeight: 680)
        .background(Color.appBackground)
        .task {
            model.pruneMissingFiles()
            await model.refreshIndexStats(root: vm.explorerRootPath)
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
                if let paths = newCollectionPaths {
                    vm.createCollection(named: newCollectionName, paths: paths, fallbackName: "Similar Images")
                }
                newCollectionPaths = nil
            }
            Button("Cancel", role: .cancel) { newCollectionPaths = nil }
        } message: {
            Text("Create a collection with the files in this group.")
        }
    }

    // MARK: - Controls

    private var controls: some View {
        @Bindable var vm = vm
        return HStack(spacing: AppSpacing.lg) {
            Picker("Scope", selection: $vm.visualSearchScope) {
                ForEach(VisualSearchScopeChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Scope")

            HStack(spacing: AppSpacing.sm) {
                Text("Strictness")
                    .font(.appCalloutEmphasis)
                    .foregroundStyle(Color.appMuted)
                Slider(value: $strictness, in: 0.5...1)
                    .tint(Color.appAccent)
                    .frame(width: 150)
                    .accessibilityLabel("Strictness")
                Text(strictnessLabel)
                    .font(.appFootnote)
                    .foregroundStyle(Color.appMuted)
                    .frame(width: 92, alignment: .leading)
            }

            Toggle("Include videos", isOn: $includeVideos)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.appCallout)

            Spacer(minLength: 0)

            if model.isComputing {
                ProgressView().controlSize(.small)
            }

            Button {
                run()
            } label: {
                Label("Find Similar", systemImage: "sparkle.magnifyingglass")
                    .font(.appCalloutEmphasis)
            }
            .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
            .disabled(model.isComputing || vm.currentVisualScope == nil)
        }
    }

    private var strictnessLabel: String {
        switch strictness {
        case 0.99...: return "identical only"
        case 0.85...: return "near-identical"
        case 0.7...: return "very similar"
        default: return "loosely similar"
        }
    }

    private func indexingBanner(_ progress: (done: Int, total: Int)) -> some View {
        HStack(spacing: AppSpacing.sm) {
            ProgressView(value: Double(min(progress.done, progress.total)), total: Double(progress.total))
                .frame(width: 120)
                .tint(Color.appAccent)
            Text("Indexing \(progress.done.formatted()) of \(progress.total.formatted()) — results may be incomplete until it finishes.")
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
            Spacer()
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.bottom, AppSpacing.md)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isComputing && model.sets.isEmpty {
            VStack(spacing: AppSpacing.md) {
                ProgressView().controlSize(.small)
                Text("Comparing images \(vm.visualScopeDescription)…")
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.indexedCount == 0 && model.sets.isEmpty {
            notIndexedState
        } else if model.sets.isEmpty {
            FeatureEmptyState(
                systemImage: model.hasSearched ? "checkmark.seal" : "square.on.square",
                title: model.hasSearched ? "No similar images found" : "Find exact copies and near-duplicates",
                message: model.hasSearched
                    ? "Nothing \(vm.visualScopeDescription) is that alike. Lower the strictness to find looser matches, or search the whole library."
                    : "Choose This Folder or Whole Library and a strictness, then click Find Similar. Nothing is changed — every file stays where it is."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.lg) {
                    ForEach(Array(model.sets.enumerated()), id: \.element.id) { index, set in
                        groupCard(index: index, set: set)
                    }
                }
                .padding(AppSpacing.xl)
            }
            .opacity(model.isComputing ? 0.5 : 1)
        }
    }

    private var notIndexedState: some View {
        FeatureEmptyState(
            systemImage: "photo.stack",
            title: "Images haven't been indexed yet",
            message: notIndexedMessage
        ) {
            HStack(spacing: AppSpacing.md) {
                if !indexController.isEnabled || indexController.state == .paused || indexController.state == .stopped,
                   let root = vm.explorerRootPath
                {
                    Button("Resume Indexing") {
                        indexController.isEnabled = true
                        if indexController.state == .paused {
                            indexController.resume()
                        } else {
                            indexController.start(root: root)
                        }
                    }
                    .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                }
                Button("Open Settings") {
                    vm.openSettings()
                }
                .buttonStyle(AppLabeledButtonStyle())
            }
        }
    }

    private var notIndexedMessage: String {
        switch indexController.state {
        case .indexing:
            return "Indexing is running in the background — see the indicator in the status bar. Try again once some images are done."
        case .paused:
            return "Indexing is paused. Resume it here, from the status bar indicator, or in Settings ▸ Search Index."
        case .stopped:
            return "Indexing is stopped. Resume it here or in Settings ▸ Search Index."
        default:
            return "The visual index builds automatically in the background when a folder opens. Its progress shows in the status bar; Settings ▸ Search Index has the controls."
        }
    }

    private func groupCard(index: Int, set: SimilarSet) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.md) {
                Text("Group \(index + 1)")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appPrimaryText)
                // Neutral kind label — the same styling for every group.
                Text(set.kind == .exact ? "Exact" : "Similar")
                    .font(.appMicro)
                    .foregroundStyle(Color.appMuted)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xxs)
                    .background(Capsule().fill(Color.appElevatedSurface))
                    .help(set.kind == .exact ? "Identical file contents" : "Visually alike")
                Text("\(set.paths.count) files")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)

                Spacer()

                ForEach(model.groupActions) { action in
                    groupActionControl(action, set: set, index: index)
                }
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: AppSpacing.md) {
                    ForEach(model.rows(for: set), id: \.path) { row in
                        fileTile(path: row.path, info: row.info, set: set)
                    }
                }
                .padding(.bottom, AppSpacing.xs)
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

    @ViewBuilder
    private func groupActionControl(_ action: SimilarGroupAction, set: SimilarSet, index: Int) -> some View {
        switch action {
        case .addToCollection:
            Menu {
                if !vm.collections.isEmpty {
                    CollectionMenuItems(vm: vm) { collection in
                        vm.addPaths(set.paths, toCollection: collection)
                    }
                    Divider()
                }
                Button("New Collection…") {
                    newCollectionName = "Similar Images \(index + 1)"
                    newCollectionPaths = set.paths
                }
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .font(.appCaption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(Color.appMuted)
        default:
            Button {
                perform(action, on: set)
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .font(.appCaption)
            }
            .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
            .help(help(for: action))
        }
    }

    private func help(for action: SimilarGroupAction) -> String {
        switch action {
        case .compare: return "Step through this group in the lightbox"
        case .selectInGrid: return "Select these files in the grid"
        case .revealInFinder: return "Show these files in Finder"
        case .openInLightbox: return "Open in the lightbox"
        case .addToCollection: return "Add these files to a collection"
        }
    }

    private func fileTile(path: String, info: SimilarImageInfo?, set: SimilarSet) -> some View {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            FeatureThumbnail(path: path, size: 120)
            Text(name)
                .font(.appCaption)
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detailLine(info))
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
            Text(FeatureText.relativeFolder(info?.folderPath ?? (path as NSString).deletingLastPathComponent, root: vm.explorerRootPath))
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(width: 120, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { perform(.openInLightbox, on: set, path: path) }
        .help("\(name) — double-click to open in the lightbox")
        .contextMenu {
            ForEach(model.fileActions) { action in
                Button(action.title) { perform(action, on: set, path: path) }
            }
        }
    }

    private func detailLine(_ info: SimilarImageInfo?) -> String {
        guard let info else { return " " }
        var parts: [String] = []
        if let resolution = info.resolutionText { parts.append(resolution) }
        if let size = info.sizeText { parts.append(size) }
        if info.isVideo { parts.append("Video") }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private var summaryText: String {
        guard !model.sets.isEmpty else {
            if let indexed = model.indexedCount, indexed > 0 {
                return "\(indexed.formatted()) files indexed"
            }
            return "Compares images with the visual index"
        }
        let exact = model.sets.filter { $0.kind == .exact }.count
        var text = "\(model.sets.count) group\(model.sets.count == 1 ? "" : "s") · \(model.fileCount) files"
        if exact > 0 { text += " · \(exact) exact" }
        return text + " · nothing is changed"
    }

    // MARK: - Actions

    private func run() {
        guard let scope = vm.currentVisualScope else { return }
        model.run(scope: scope, root: vm.explorerRootPath, strictness: strictness, includeVideos: includeVideos)
    }

    private func perform(_ action: SimilarGroupAction, on set: SimilarSet, path: String? = nil) {
        switch action {
        case .revealInFinder:
            vm.perform(action, on: set, path: path)
        case .compare, .selectInGrid, .openInLightbox:
            close()
            vm.perform(action, on: set, path: path)
        case .addToCollection:
            break  // handled by the menu
        }
    }

    private func close() {
        vm.similarImagesOpen = false
        dismiss()
    }
}
