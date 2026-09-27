import AppKit
import SwiftUI

/// Right side of the Similar Images page: the selected group's files large,
/// side by side, in the engine's order (folder, then name) — never sorted by
/// size or resolution, nothing highlighted as the one to keep. The focused
/// card (←/→) has an accent ring.
struct SimilarComparisonView: View {
    @Environment(ExplorerViewModel.self) private var vm
    let onNewCollection: (SimilarSet, Int) -> Void

    private var model: SimilarImagesModel { vm.similarImages }
    private var indexController: VisualIndexController { .shared }

    private static let spacing: CGFloat = AppSpacing.lg
    private static let padding: CGFloat = AppSpacing.xl
    private static let minimumCardWidth: CGFloat = 240
    /// Room under each preview for the file facts and the prompt.
    private static let infoHeight: CGFloat = 190

    var body: some View {
        Group {
            if let set = model.selectedSet, let index = model.focus.groupIndex(in: model.sets) {
                VStack(spacing: 0) {
                    groupHeader(set, index: index)
                    Divider().background(Color.appBorder)
                    // Compare toggle: the synced compare (Views/Compare) instead of the cards.
                    if ViewingController.shared.similarPageCompare, set.paths.count >= CompareEligibility.minimumCount {
                        SimilarGroupCompareView(set: set)
                    } else {
                        cards(for: set)
                    }
                }
            } else {
                emptyState
            }
        }
        .background(Color.appBackground)
    }

    // MARK: Header

    private func groupHeader(_ set: SimilarSet, index: Int) -> some View {
        HStack(spacing: AppSpacing.md) {
            Text("Group \(index + 1) of \(model.sets.count)")
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)
            SimilarKindLabel(kind: set.kind)
            Text("\(set.paths.count) files")
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
            Spacer(minLength: AppSpacing.md)
            SimilarCompareToggle()
            ForEach(SimilarGroupPageAction.displayOrder) { action in
                groupActionControl(action, set: set, index: index)
            }
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.md)
    }

    @ViewBuilder
    private func groupActionControl(_ action: SimilarGroupPageAction, set: SimilarSet, index: Int) -> some View {
        switch action {
        case .addToCollection:
            Menu {
                if !vm.collections.isEmpty {
                    CollectionMenuItems(vm: vm) { collection in
                        vm.addPaths(set.paths, toCollection: collection)
                    }
                    Divider()
                }
                Button("New Collection…") { onNewCollection(set, index) }
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .font(.appCaption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(Color.appMuted)
            .help("Add every file in this group to a collection")
        case .selectInBrowser, .openAsListing:
            Button {
                vm.performSimilarGroupAction(action, on: set)
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .font(.appCaption)
            }
            .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
            .help(action == .selectInBrowser
                ? "Back to the browser with this group's files listed and selected"
                : "Back to the browser with this group as the listing")
        }
    }

    // MARK: Cards

    private func cards(for set: SimilarSet) -> some View {
        GeometryReader { geometry in
            let rows = model.rows(for: set)
            let layout = Self.layout(count: rows.count, size: geometry.size)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(layout.cardWidth), spacing: Self.spacing, alignment: .top),
                            count: layout.columns
                        ),
                        alignment: .leading,
                        spacing: Self.spacing
                    ) {
                        ForEach(rows, id: \.path) { row in
                            SimilarImageCard(
                                path: row.path,
                                info: row.info,
                                previewSize: CGSize(width: layout.cardWidth, height: layout.previewHeight),
                                isFocused: model.focusedPath == row.path
                            )
                            .id(row.path)
                        }
                    }
                    .padding(Self.padding)
                }
                .onChange(of: model.focusedPath) { _, path in
                    guard let path else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(path) }
                }
            }
        }
    }

    /// 2 files → two columns; 3–4 → as many columns as fit (4 goes 2 × 2
    /// rather than 3 + 1); more wrap and scroll. Previews fill the height when
    /// every card fits on screen.
    static func layout(count: Int, size: CGSize) -> (columns: Int, cardWidth: CGFloat, previewHeight: CGFloat) {
        let usableWidth = max(size.width - padding * 2, minimumCardWidth)
        let fitting = max(1, Int((usableWidth + spacing) / (minimumCardWidth + spacing)))
        var columns = max(1, min(count, fitting))
        if count == 4, columns == 3 { columns = 2 }
        let cardWidth = floor((usableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let rowCount = max(1, Int(ceil(Double(max(count, 1)) / Double(columns))))
        let usableHeight = size.height - padding * 2 - spacing * CGFloat(rowCount - 1)
        let fitHeight = usableHeight / CGFloat(rowCount) - infoHeight
        let previewHeight = max(180, min(cardWidth * 1.25, fitHeight))
        return (columns, max(cardWidth, 120), previewHeight)
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptyState: some View {
        if vm.currentVisualScope == nil {
            FeatureEmptyState(
                systemImage: "folder",
                title: "No folder open",
                message: "Open a folder to compare its images."
            ) {
                Button("Open Folder…") { Task { await vm.openFolder() } }
                    .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
            }
        } else if model.isComputing && model.sets.isEmpty {
            VStack(spacing: AppSpacing.md) {
                ProgressView().controlSize(.small)
                Text("Comparing images \(vm.visualScopeDescription)…")
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.indexedCount == 0 {
            notIndexedState
        } else if model.hasSearched {
            FeatureEmptyState(
                systemImage: "checkmark.seal",
                title: "No similar images found",
                message: noGroupsMessage
            ) {
                HStack(spacing: AppSpacing.md) {
                    if model.strictness > SimilarImagesModel.strictnessRange.lowerBound + 0.05 {
                        Button("Lower Strictness") {
                            model.strictness = max(SimilarImagesModel.strictnessRange.lowerBound, model.strictness - 0.1)
                            vm.runSimilarImagesSearch()
                        }
                        .buttonStyle(AppLabeledButtonStyle())
                    }
                    if vm.visualSearchScope == .folder {
                        Button("Search Whole Library") { vm.visualSearchScope = .library }
                            .buttonStyle(AppLabeledButtonStyle())
                    }
                }
            }
        } else {
            FeatureEmptyState(
                systemImage: "square.on.square",
                title: "Find exact copies and near-duplicates",
                message: "Choose This Folder or Whole Library and a strictness, then click Find. Nothing is changed — every file stays where it is."
            )
        }
    }

    private var noGroupsMessage: String {
        var text = "Nothing \(vm.visualScopeDescription) is that alike."
        text += vm.visualSearchScope == .folder
            ? " Lower the strictness to find looser matches, or search the whole library."
            : " Lower the strictness to find looser matches."
        if indexController.state == .indexing { text += " Indexing is still running." }
        return text
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
                Button("Open Settings") { vm.openSettings() }
                    .buttonStyle(AppLabeledButtonStyle())
            }
        }
    }

    private var notIndexedMessage: String {
        switch indexController.state {
        case .indexing:
            return "Indexing is running in the background — see the indicator on the left or in the status bar. Try again once some images are done."
        case .paused:
            return "Indexing is paused. Resume it here, from the status bar indicator, or in Settings ▸ Search Index."
        case .stopped:
            return "Indexing is stopped. Resume it here or in Settings ▸ Search Index."
        default:
            return "The visual index builds automatically in the background when a folder opens. Its progress shows in the status bar; Settings ▸ Search Index has the controls."
        }
    }
}

// MARK: - Card

/// One file of the group: a large aspect-fit preview (downsampled through
/// ThumbnailService at the card's size × screen scale), then neutral facts,
/// flag / rating / label badges and the prompt.
struct SimilarImageCard: View {
    @Environment(ExplorerViewModel.self) private var vm
    let path: String
    let info: SimilarImageInfo?
    let previewSize: CGSize
    let isFocused: Bool

    @State private var isHovered = false
    @State private var promptExpanded = false
    @State private var flash: SimilarCardFeedback?

    private var model: SimilarImagesModel { vm.similarImages }
    private var url: URL { URL(fileURLWithPath: path) }
    private var name: String { url.lastPathComponent }
    private var isVideo: Bool { info?.isVideo ?? FileHelpers.isVideoFile(name) }
    private var flag: FileFlag { vm.flag(for: path) }
    private var rating: Int { vm.rating(for: path) }
    private var label: FinderLabel { FinderLabel(labelNumber: info?.labelNumber) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            preview
            facts
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(isFocused ? Color.appAccent : Color.appBorder, lineWidth: isFocused ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .simultaneousGesture(TapGesture().onEnded { model.focus(path: path) })
        .onTapGesture(count: 2) { vm.performSimilarCardAction(.openInLightbox, path: path) }
        .onHover { isHovered = $0 }
        .contextMenu { contextMenu }
        .task(id: path) { model.loadPrompt(for: path) }
        .onChange(of: model.cardFeedback) { _, feedback in
            guard let feedback, feedback.paths.contains(path) else { return }
            flash = feedback
        }
        .help("\(name) — double-click to open in the lightbox")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Color.appCanvasBackground)
            SimilarCardPreview(path: path, boxSize: CGSize(width: previewSize.width - AppSpacing.md * 2, height: previewSize.height))
                .padding(AppSpacing.xs)
            if isVideo {
                Button {
                    vm.performSimilarCardAction(.openInLightbox, path: path)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.appIcon(20, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .help("Play in the lightbox")
                .accessibilityLabel("Play \(name) in the lightbox")
            }
        }
        .frame(height: previewSize.height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(alignment: .topLeading) {
            TileCullBadges(flag: flag, label: label, side: 22)
                .padding(AppSpacing.sm)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if isHovered || isFocused {
                hoverActions
                    .padding(AppSpacing.sm)
                    .opacity(isHovered ? 1 : 0.85)
            }
        }
        .overlay(alignment: .bottom) {
            if let flash {
                Text(flash.action.feedbackTitle)
                    .font(.appCalloutEmphasis)
                    .foregroundStyle(Color.appPrimaryText)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.sm)
                    .background(Capsule().fill(Color.appOverlaySurface))
                    .overlay(Capsule().strokeBorder(Color.appOverlayStroke, lineWidth: 1))
                    .padding(AppSpacing.md)
                    .transition(.opacity)
                    .task(id: flash.id) {
                        try? await Task.sleep(for: .milliseconds(900))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.2)) { self.flash = nil }
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    private var hoverActions: some View {
        HStack(spacing: AppSpacing.xxs) {
            ForEach(SimilarCardAction.displayOrder) { action in
                Button {
                    vm.performSimilarCardAction(action, path: path)
                } label: {
                    Image(systemName: action.systemImage)
                        .font(.appIcon(12, weight: .medium))
                }
                .buttonStyle(AppIconButtonStyle(width: 26, height: 26, cornerRadius: AppRadius.sm))
                .help(action.title + (action == .moreLikeThis ? " (M)" : ""))
                .accessibilityLabel(action.title)
            }
        }
        .padding(AppSpacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Color.appOverlaySurface)
        )
    }

    // MARK: Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(name)
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(FeatureText.relativeFolder(info?.folderPath ?? (path as NSString).deletingLastPathComponent, root: vm.explorerRootPath))
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
                .truncationMode(.head)
            Text(detailLine)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
                .monospacedDigit()
            badges
            promptView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailLine: String {
        var parts: [String] = []
        if let resolution = info?.resolutionText { parts.append(resolution) }
        if let size = info?.sizeText { parts.append(size) }
        if let date = info?.modifiedDate {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        if isVideo { parts.append("Video") }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private var badges: some View {
        HStack(spacing: AppSpacing.md) {
            if flag != .unflagged {
                Label(flag.title, systemImage: flag.systemImage)
                    .font(.appCaption)
                    .foregroundStyle(flag.tint)
                    .labelStyle(.titleAndIcon)
            }
            if rating > 0 {
                StarRatingView(rating: rating, size: 10)
            }
            if label != .none {
                LabelCell(label: label)
            }
            if flag == .unflagged, rating == 0, label == .none {
                Text("No flag, rating or label")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted.opacity(0.7))
            }
        }
        .frame(height: 16)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var promptView: some View {
        if let prompt = model.prompts[path] {
            if prompt.isEmpty {
                Text(isVideo ? "No prompt (video)" : "No prompt")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted.opacity(0.7))
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    // Not selectable: a text-view first responder would take the page's keys.
                    Text(prompt)
                        .font(.appCallout)
                        .foregroundStyle(Color.appPrimaryText.opacity(0.85))
                        .lineLimit(promptExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                    if prompt.count > 140 || prompt.contains("\n") {
                        Button(promptExpanded ? "Show Less" : "Show More") {
                            withAnimation(.easeInOut(duration: 0.15)) { promptExpanded.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.appCaptionEmphasis)
                        .foregroundStyle(Color.appAccent)
                    }
                }
            }
        } else {
            Text("Loading prompt…")
                .font(.appCaption)
                .foregroundStyle(Color.appMuted.opacity(0.7))
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        ForEach(SimilarCardAction.displayOrder) { action in
            Button(action.title + (action == .moreLikeThis ? " (M)" : "")) {
                vm.performSimilarCardAction(action, path: path)
            }
        }
        Divider()
        CullActionMenus(flag: flag, rating: rating, label: label) { action in
            vm.applySimilarCardCull(action, path: path)
        }
    }
}

/// Aspect-fit preview for a card. Always a downsampled decode
/// (`ThumbnailService.thumbnail(for:size:)`: ImageIO for images, a poster
/// frame for video) at the box size, bucketed so resizing doesn't reload
/// every step — never the full-resolution file.
struct SimilarCardPreview: View {
    let path: String
    let boxSize: CGSize

    @State private var image: NSImage?

    private var url: URL { URL(fileURLWithPath: path) }

    /// Point size handed to ThumbnailService (it multiplies by the screen scale).
    static func bucketedSize(for box: CGSize) -> CGFloat {
        let longest = max(box.width, box.height, 64)
        let step: CGFloat = 128
        return min(1024, (longest / step).rounded(.up) * step)
    }

    var body: some View {
        let size = Self.bucketedSize(for: boxSize)
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(path)|\(Int(size))") {
            if let cached = ThumbnailService.shared.cachedThumbnail(for: url, size: size) {
                image = cached
                return
            }
            let loaded = await ThumbnailService.shared.thumbnail(for: url, size: size)
            guard !Task.isCancelled else { return }
            if let loaded { image = loaded }
        }
    }
}
