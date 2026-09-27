import AppKit
import SwiftUI

/// Library ▸ Similar Images: a full page over the content browser and the
/// details panel (the sidebar stays). Left: the groups, with the search
/// controls. Right: the selected group's files side by side, large.
///
/// HARD RULE (user decision): groups are for inspection only. No file is
/// marked, pre-selected, highlighted as "best" or offered for removal —
/// higher-resolution copies are often upscales of a master. There is no
/// trash / delete affordance anywhere on this page.
///
/// Keys are owned by the main window's key monitor (`handleGlobalKey` →
/// `SimilarPageKeyAction`): ↑/↓ groups, ←/→ cards, Space/Return lightbox,
/// M More Like This, P X U 0–9 culling on the focused card, Esc back to the browser.
struct SimilarImagesPageView: View {
    @Environment(ExplorerViewModel.self) private var vm

    @AppStorage("similarImages.groupListWidth") private var storedListWidth: Double = 300
    @State private var dragStartWidth: Double?
    @State private var liveListWidth: Double?
    @State private var newCollectionPaths: [String]?
    @State private var newCollectionName = ""

    private static let listWidthRange: ClosedRange<Double> = 240...560
    private static let minimumComparisonWidth: Double = 360

    private var model: SimilarImagesModel { vm.similarImages }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            Divider().background(Color.appBorder)
            GeometryReader { geometry in
                let listWidth = clampedListWidth(liveListWidth ?? storedListWidth, total: geometry.size.width)
                HStack(spacing: 0) {
                    SimilarGroupListView()
                        .frame(width: listWidth)
                    splitHandle(total: geometry.size.width, current: listWidth)
                    SimilarComparisonView(onNewCollection: promptForNewCollection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.appBackground)
        .task {
            model.pruneMissingFiles()
            await model.refreshIndexStats(root: vm.explorerRootPath)
        }
        // Sidebar folder clicks, back / forward, the scope control.
        .onChange(of: vm.similarPageContext) { old, new in
            vm.similarPageContextChanged(from: old, to: new)
        }
        .onChange(of: VisualIndexController.shared.lastCompleted) { _, _ in
            Task { await model.refreshIndexStats(root: vm.explorerRootPath) }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Similar Images")
    }

    // MARK: Header

    private var pageHeader: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "square.on.square")
                .font(.appIcon(15, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Similar Images")
                    .font(.appTitle)
                    .foregroundStyle(Color.appPrimaryText)
                Text("Exact copies and near-duplicates, side by side. Every file is kept — this is for looking, not cleaning up.")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: AppSpacing.lg)
            // Esc is owned by the key monitor (no key equivalent here).
            Button {
                vm.leaveSimilarImagesPage()
            } label: {
                Text("Done")
                    .font(.appCalloutEmphasis)
            }
            .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
            .help("Back to the browser (Esc)")
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.md)
        .background(Color.appSurface)
    }

    // MARK: Split

    private func clampedListWidth(_ width: Double, total: Double) -> Double {
        let upper = max(Self.listWidthRange.lowerBound, min(Self.listWidthRange.upperBound, total - Self.minimumComparisonWidth))
        return min(max(width, Self.listWidthRange.lowerBound), upper)
    }

    private func splitHandle(total: Double, current: Double) -> some View {
        Rectangle()
            .fill(Color.appBorder)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                // A wider, invisible grab area over the hairline.
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? current
                                if dragStartWidth == nil { dragStartWidth = current }
                                liveListWidth = clampedListWidth(start + value.translation.width, total: total)
                            }
                            .onEnded { _ in
                                if let liveListWidth { storedListWidth = liveListWidth }
                                liveListWidth = nil
                                dragStartWidth = nil
                            }
                    )
            }
            .accessibilityHidden(true)
    }

    private func promptForNewCollection(_ set: SimilarSet, index: Int) {
        newCollectionName = "Similar Images \(index + 1)"
        newCollectionPaths = set.paths
    }
}

// MARK: - Group list (left)

/// Search controls, a result summary and one row per group.
struct SimilarGroupListView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var hoveredGroupID: String?

    private var model: SimilarImagesModel { vm.similarImages }
    private var indexController: VisualIndexController { .shared }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().background(Color.appBorder)
            groupList
        }
        .background(Color.appSurface)
    }

    // MARK: Controls

    private var controls: some View {
        @Bindable var vm = vm
        @Bindable var model = vm.similarImages
        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            Picker("Scope", selection: $vm.visualSearchScope) {
                ForEach(VisualSearchScopeChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Scope")

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack {
                    Text("Strictness")
                        .font(.appCalloutEmphasis)
                        .foregroundStyle(Color.appMuted)
                    Spacer()
                    Text(strictnessLabel)
                        .font(.appFootnote)
                        .foregroundStyle(Color.appMuted)
                }
                Slider(value: $model.strictness, in: SimilarImagesModel.strictnessRange) { editing in
                    if !editing { vm.runSimilarImagesSearch() }
                }
                .tint(Color.appAccent)
                .accessibilityLabel("Strictness")
                .accessibilityValue(strictnessLabel)
            }

            HStack(spacing: AppSpacing.md) {
                Toggle("Include Videos", isOn: $model.includeVideos)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.appCallout)
                    .onChange(of: model.includeVideos) { _, _ in vm.runSimilarImagesSearch() }
                Spacer(minLength: 0)
                if model.isComputing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    vm.runSimilarImagesSearch(force: true)
                } label: {
                    Label("Find", systemImage: "sparkle.magnifyingglass")
                        .font(.appCalloutEmphasis)
                }
                .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                .disabled(model.isComputing || vm.currentVisualScope == nil)
                .help("Search again with these settings")
            }

            Text(summaryText)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .lineLimit(2)
                .truncationMode(.middle)
                .accessibilityLabel(summaryText)

            if model.isStale, !model.isComputing {
                Button {
                    vm.runSimilarImagesSearch(force: true)
                } label: {
                    Label("The index changed — refresh", systemImage: "arrow.clockwise")
                        .font(.appCaption)
                }
                .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
            }

            if showsIndexingBanner {
                indexingBanner
            }
        }
        .padding(AppSpacing.lg)
    }

    /// The visual index isn't complete: running, paused, stopped, or never built.
    private var showsIndexingBanner: Bool {
        switch indexController.state {
        case .indexing, .paused, .stopped: return true
        case .idle: return (model.indexedCount ?? 1) == 0
        case .completed: return false
        }
    }

    private var strictnessLabel: String {
        switch model.strictness {
        case 0.99...: return "identical only"
        case 0.85...: return "near-identical"
        case 0.7...: return "very similar"
        default: return "loosely similar"
        }
    }

    private var scopeName: String {
        switch vm.visualSearchScope {
        case .folder:
            let folder = vm.selectedFolderPath ?? vm.explorerRootPath
            return "This Folder: \(folder?.lastPathComponent ?? "—")"
        case .library:
            return "Whole Library: \(vm.explorerRootPath?.lastPathComponent ?? "—")"
        }
    }

    private var summaryText: String {
        if model.isComputing, model.sets.isEmpty { return "Comparing images · \(scopeName)" }
        guard model.hasSearched else { return scopeName }
        let groups = model.sets.count
        let files = model.fileCount
        return "\(groups) group\(groups == 1 ? "" : "s") · \(files) image\(files == 1 ? "" : "s") · \(scopeName)"
    }

    @ViewBuilder
    private var indexingBanner: some View {
        let state = indexController.state
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: state == .indexing ? "hourglass" : "exclamationmark.circle")
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                    .accessibilityHidden(true)
                Text(bannerText)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state == .indexing, let progress = indexController.progress, progress.total > 0 {
                ProgressView(value: Double(min(progress.done, progress.total)), total: Double(progress.total))
                    .tint(Color.appAccent)
            }
            HStack(spacing: AppSpacing.sm) {
                // Same indicator (and Pause / Resume / Stop popover) as the browser's status bar.
                VisualIndexStatusItem()
                Spacer(minLength: 0)
                Button("Settings…") { vm.openSettings() }
                    .buttonStyle(AppLabeledButtonStyle(height: 22, horizontalPadding: AppSpacing.sm))
                    .font(.appCaption)
                    .help("Settings ▸ Search Index")
            }
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Color.appElevatedSurface.opacity(0.6))
        )
    }

    private var bannerText: String {
        switch indexController.state {
        case .indexing:
            if let progress = indexController.progress, progress.total > 0 {
                return "Indexing \(progress.done.formatted()) of \(progress.total.formatted()) — results may be incomplete until it finishes."
            }
            return "Indexing images — results may be incomplete until it finishes."
        case .paused: return "Visual indexing is paused — results may be incomplete."
        case .stopped: return "Visual indexing is stopped — newer files aren't compared."
        default: return "The visual index isn't built yet for this library."
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var groupList: some View {
        if model.sets.isEmpty {
            VStack(spacing: AppSpacing.sm) {
                if model.isComputing {
                    ProgressView().controlSize(.small)
                }
                Text(model.isComputing ? "Comparing…" : (model.hasSearched ? "No groups" : " "))
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: AppSpacing.xxs) {
                        ForEach(Array(model.sets.enumerated()), id: \.element.id) { index, set in
                            row(set, index: index)
                                .id(set.id)
                        }
                    }
                    .padding(AppSpacing.sm)
                }
                .opacity(model.isComputing ? 0.55 : 1)
                .onChange(of: model.focus.groupID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
                .onAppear {
                    if let id = model.focus.groupID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func row(_ set: SimilarSet, index: Int) -> some View {
        let isSelected = model.focus.groupID == set.id
        return HStack(spacing: AppSpacing.md) {
            thumbnailStrip(set)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                HStack(spacing: AppSpacing.sm) {
                    Text("Group \(index + 1)")
                        .font(.appCalloutEmphasis)
                        .foregroundStyle(Color.appPrimaryText)
                    SimilarKindLabel(kind: set.kind)
                }
                Text("\(set.paths.count) files")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.sm)
        .background(FeatureRowBackground(isSelected: isSelected, isHovered: hoveredGroupID == set.id))
        .contentShape(Rectangle())
        .onTapGesture { model.selectGroup(set.id) }
        .onHover { inside in
            if inside { hoveredGroupID = set.id } else if hoveredGroupID == set.id { hoveredGroupID = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Group \(index + 1), \(set.kind == .exact ? "exact copies" : "similar"), \(set.paths.count) files")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func thumbnailStrip(_ set: SimilarSet) -> some View {
        let shown = Array(set.paths.prefix(4))
        let extra = set.paths.count - shown.count
        return HStack(spacing: AppSpacing.xxs) {
            ForEach(shown, id: \.self) { path in
                FeatureThumbnail(path: path, size: 34)
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.appMicro)
                    .foregroundStyle(Color.appMuted)
                    .frame(width: 26, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                            .fill(Color.appElevatedSurface)
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

/// "Exact" / "Similar" — the same neutral styling for both.
struct SimilarKindLabel: View {
    let kind: SimilarSet.Kind

    var body: some View {
        Text(kind == .exact ? "Exact" : "Similar")
            .font(.appMicro)
            .foregroundStyle(Color.appMuted)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xxs)
            .background(Capsule().fill(Color.appElevatedSurface))
            .help(kind == .exact ? "Identical file contents" : "Visually alike")
    }
}
