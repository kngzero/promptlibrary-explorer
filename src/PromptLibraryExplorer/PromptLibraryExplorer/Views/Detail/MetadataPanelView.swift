import AVKit
import SwiftUI

struct MetadataPanelView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var previewPaneRatio: CGFloat = 0.42
    @State private var dragStartPreviewRatio: CGFloat?
    @State private var previewVideoPlayer = AVPlayer()

    private let dividerHeight: CGFloat = 12
    private let minimumPreviewHeight: CGFloat = 150
    private let minimumMetadataHeight: CGFloat = 220

    var body: some View {
        Group {
            if let entry = vm.selectedPromptEntry {
                VStack(spacing: 0) {
                    HStack {
                        Text("Details")
                            .font(.appIcon(16, weight: .semibold))
                            .foregroundStyle(Color.appPrimaryText)
                        Spacer()

                        // Toggle preview pane
                        Button {
                            vm.togglePreviewPane()
                        } label: {
                            Image(systemName: vm.previewPaneCollapsed ? "eye.slash" : "eye")
                                .font(.appCallout)
                        }
                        .buttonStyle(AppIconButtonStyle(width: 24, height: 24, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                        .help(vm.previewPaneCollapsed ? "Show Preview" : "Hide Preview")
                        .accessibilityLabel(vm.previewPaneCollapsed ? "Show Preview" : "Hide Preview")
                    }
                    .padding(.horizontal, AppSpacing.xl)
                    .frame(height: LayoutMetrics.panelHeaderHeight)
                    .background(Color.appBackground)
                    .overlay(alignment: .bottom) {
                        Divider().background(Color.appBorder)
                    }

                    GeometryReader { geometry in
                        detailSplitView(entry: entry, availableHeight: geometry.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                VStack(spacing: AppSpacing.md) {
                    Image(systemName: "sidebar.right")
                        .font(.appIcon(32))
                        .foregroundStyle(Color.appMuted.opacity(0.5))
                    Text("Select an item to view details")
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.appSidebarBackground)
        // The lightbox has its own player; keep the preview player from playing
        // underneath it (which would double the audio).
        .onChange(of: vm.lightboxOpen) { _, isOpen in
            if isOpen {
                previewVideoPlayer.pause()
            }
        }
        .onChange(of: vm.selectedPromptEntry?.sourcePath) { _, _ in
            previewVideoPlayer.pause()
        }
        .onDisappear {
            clearPreviewVideoPlayer()
        }
        .sheet(isPresented: Binding(
            get: { vm.metadataEditorPath != nil },
            set: { if !$0 { vm.metadataEditorPath = nil } }
        )) {
            if let path = vm.metadataEditorPath {
                MetadataEditorView(
                    filePath: path,
                    existingEntry: vm.selectedPromptEntry
                )
                .environment(vm)
            }
        }
    }

    @ViewBuilder
    private func detailSplitView(entry: PromptEntry, availableHeight: CGFloat) -> some View {
        if vm.previewPaneCollapsed {
            // Preview hidden — full height metadata
            metadataPane(entry: entry)
                .frame(maxHeight: .infinity)
        } else {
            let previewHeight = resolvedPreviewHeight(for: availableHeight)
            let metadataHeight = max(0, availableHeight - previewHeight - dividerHeight)

            VStack(spacing: 0) {
                previewPane(entry: entry)
                    .frame(height: previewHeight)

                resizeDivider(totalHeight: availableHeight)

                metadataPane(entry: entry)
                    .frame(height: metadataHeight)
            }
        }
    }

    @ViewBuilder
    private func previewPane(entry: PromptEntry) -> some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.appSurface.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .strokeBorder(Color.appBorder, lineWidth: 1)
                    )

                if let videoURL = entry.videoURL {
                    VideoPlayerSurface(
                        player: previewVideoPlayer,
                        allowsPictureInPicturePlayback: false
                    )
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                        .padding(AppSpacing.lg)
                        .task(id: videoURL.standardizedFileURL.path) {
                            preparePreviewVideoPlayer(for: videoURL)
                        }
                        .onDisappear {
                            clearPreviewVideoPlayer()
                        }
                } else if let audioURL = entry.audioURL {
                    AudioPlayerView(
                        player: previewVideoPlayer,
                        fileName: URL(fileURLWithPath: entry.sourcePath ?? audioURL.path).lastPathComponent
                    )
                        .frame(maxWidth: 420)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(AppSpacing.lg)
                        .task(id: audioURL.standardizedFileURL.path) {
                            preparePreviewVideoPlayer(for: audioURL)
                        }
                        .onDisappear {
                            clearPreviewVideoPlayer()
                        }
                } else if let firstImage = entry.images.first {
                    Image(nsImage: firstImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                        .padding(AppSpacing.lg)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo")
                            .font(.appIcon(28))
                            .foregroundStyle(Color.appMuted.opacity(0.7))
                        Text("No preview available")
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.lg)
        }
    }

    /// Whether this entry is a supported media file for metadata embedding.
    private func isEmbeddableMetadataFile(_ entry: PromptEntry) -> Bool {
        guard let path = entry.sourcePath else { return false }
        return vm.isEmbeddableMetadataFile(path)
    }

    @ViewBuilder
    private func metadataPane(entry: PromptEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                if !entry.prompt.isEmpty {
                    detailCard(title: nil) {
                        HStack(alignment: .top, spacing: AppSpacing.sm) {
                            Image(systemName: "text.quote")
                                .font(.appCallout)
                                .foregroundStyle(Color.appAccent)
                            Text("Prompt")
                                .font(.appHeadline)
                                .foregroundStyle(Color.appPrimaryText)
                            Spacer()
                            PromptExportMenu(entry: entry, title: "Copy As") { formatName in
                                vm.showToast("Copied as \(formatName)", type: .success)
                            }
                            Button {
                                saveSnippet(text: entry.prompt, category: "Prompts")
                            } label: {
                                Image(systemName: "text.badge.star")
                                    .font(.appCaption)
                            }
                            .buttonStyle(AppIconButtonStyle(width: 22, height: 22, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                            .help("Save as Snippet")
                            .accessibilityLabel("Save as Snippet")
                            Button {
                                ClipboardService.copyString(entry.prompt)
                                vm.showToast("Prompt copied", type: .success)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.appCaption)
                            }
                            .buttonStyle(AppIconButtonStyle(width: 22, height: 22, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                            .help("Copy Prompt")
                            .accessibilityLabel("Copy Prompt")
                        }
                        Text(entry.prompt)
                            .font(.appBody)
                            .foregroundStyle(Color.appPrimaryText.opacity(0.9))
                            .textSelection(.enabled)
                            .padding(.top, AppSpacing.xs)
                    }
                }

                if isEmbeddableMetadataFile(entry), let path = entry.sourcePath {
                    let hasMetadata = !entry.prompt.isEmpty
                        || !entry.embeddedMetadata.isEmpty
                        || entry.generationInfo.model != "N/A"
                    let actionTitle = metadataActionTitle(for: path, hasMetadata: hasMetadata)
                    Button {
                        vm.openMetadataEditor(for: path)
                    } label: {
                        HStack(spacing: AppSpacing.sm) {
                            Image(systemName: hasMetadata ? "pencil.line" : "plus.square")
                                .font(.appCallout)
                            Text(actionTitle)
                                .font(.appIcon(12, weight: .medium))
                        }
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(Color.appAccent.opacity(0.12))
                        .cornerRadius(AppRadius.md)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.md)
                                .strokeBorder(Color.appAccent.opacity(0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(AppAdaptiveButtonStyle())
                }

                if entry.comfyWorkflowJSON != nil || entry.comfyPromptJSON != nil {
                    detailCard(title: "ComfyUI Workflow") {
                        ComfyWorkflowSection(entry: entry)
                    }
                }

                if entry.generationInfo.model != "N/A" {
                    detailCard(title: "Generation Info") {
                        genInfoGrid(entry.generationInfo)
                    }
                }

                if let meta = entry.fileMetadata {
                    detailCard(title: "File Name") {
                        Text(meta.fileName)
                            .font(.appBody)
                            .foregroundStyle(Color.appPrimaryText)
                            .textSelection(.enabled)
                    }

                    // Star Rating & Favorite
                    if let path = entry.sourcePath {
                        HStack {
                            Text("Rating")
                                .font(.appCalloutEmphasis)
                                .foregroundStyle(Color.appMuted)
                            Spacer()

                            // Favorite toggle
                            Button {
                                vm.toggleFavorite(path: path)
                            } label: {
                                Image(systemName: vm.isFavorite(path: path) ? "pin.fill" : "pin")
                                    .font(.appCallout)
                            }
                            .buttonStyle(
                                AppIconButtonStyle(
                                    width: 24,
                                    height: 24,
                                    cornerRadius: AppRadius.sm,
                                    showsRestingChrome: false,
                                    restingForeground: vm.isFavorite(path: path) ? Color.favoriteGoldText : Color.appMuted
                                )
                            )
                            .help(vm.isFavorite(path: path) ? "Unpin" : "Pin")
                            .accessibilityLabel(vm.isFavorite(path: path) ? "Unpin" : "Pin")

                            StarRatingView(rating: vm.rating(for: path), size: 16) { newRating in
                                vm.setRating(newRating, for: path)
                            }
                        }
                        .padding(.horizontal, AppSpacing.xl)
                        .padding(.vertical, AppSpacing.md)

                        // Tags
                        let fileTags = vm.tagsForFile(at: path)
                        if !fileTags.isEmpty || !vm.allTags.isEmpty {
                            HStack(spacing: AppSpacing.sm) {
                                Text("Tags")
                                    .font(.appCalloutEmphasis)
                                    .foregroundStyle(Color.appMuted)

                                TagPillsView(tags: fileTags)

                                Spacer()

                                Menu {
                                    TagAssignmentMenu(paths: [path])
                                } label: {
                                    Image(systemName: "plus.circle")
                                        .font(.appCaption)
                                        .foregroundStyle(Color.appMuted)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Assign Tags")
                                .accessibilityLabel("Assign Tags")
                            }
                            .padding(.horizontal, AppSpacing.xl)
                            .padding(.vertical, AppSpacing.xs)
                        }
                    }

                    fileInfoCard(meta)

                    if !entry.embeddedMetadata.isEmpty {
                        embeddedMetadataCard(entry.embeddedMetadata)
                    }
                }

                if !entry.referenceImages.isEmpty {
                    detailCard(title: "Reference Images") {
                        HStack(spacing: AppSpacing.md) {
                            ForEach(Array(entry.referenceImages.enumerated()), id: \.offset) { index, img in
                                referenceImageThumbnail(
                                    img,
                                    index: index,
                                    fileName: entry.fileMetadata?.fileName ?? "image"
                                )
                            }
                        }
                    }
                }

                if let analysis = entry.analysis {
                    let segments = analysis.segments
                    if !segments.isEmpty {
                        ForEach(segments, id: \.key) { seg in
                            AnalysisCard(
                                label: seg.label,
                                key: seg.key,
                                value: seg.value,
                                onSaveSnippet: {
                                    saveSnippet(text: seg.value, category: seg.label, title: seg.label)
                                }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.lg)
        }
    }

    @ViewBuilder
    private func resizeDivider(totalHeight: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.appBorder.opacity(0.55))
                .frame(height: 1)

            Capsule()
                .fill(Color.appBorder.opacity(0.9))
                .frame(width: 34, height: 3)
        }
        .frame(height: dividerHeight)
        .background(Color.clear)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartPreviewRatio == nil {
                        dragStartPreviewRatio = previewPaneRatio
                    }

                    let startRatio = dragStartPreviewRatio ?? previewPaneRatio
                    let startHeight = startRatio * totalHeight
                    let candidateHeight = startHeight + value.translation.height
                    let bounds = previewHeightBounds(for: totalHeight)
                    let clampedHeight = min(max(candidateHeight, bounds.lowerBound), bounds.upperBound)
                    previewPaneRatio = clampedHeight / max(totalHeight, 1)
                }
                .onEnded { _ in
                    dragStartPreviewRatio = nil
                }
        )
    }

    private func resolvedPreviewHeight(for totalHeight: CGFloat) -> CGFloat {
        let bounds = previewHeightBounds(for: totalHeight)
        let preferredHeight = previewPaneRatio * totalHeight
        return min(max(preferredHeight, bounds.lowerBound), bounds.upperBound)
    }

    private func previewHeightBounds(for totalHeight: CGFloat) -> ClosedRange<CGFloat> {
        let effectiveHeight = max(totalHeight - dividerHeight, 1)
        let minimumPreview = min(minimumPreviewHeight, effectiveHeight * 0.65)
        let minimumMetadata = min(minimumMetadataHeight, max(0, effectiveHeight - minimumPreview))
        let maximumPreview = max(minimumPreview, effectiveHeight - minimumMetadata)
        return minimumPreview...maximumPreview
    }

    /// Saves `text` to the snippet library and confirms with a toast.
    private func saveSnippet(text: String, category: String, title: String = "") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let snippet = SnippetService.shared.add(title: title, text: trimmed, category: category)
        vm.showToast("Saved snippet \"\(snippet.title)\"", type: .success)
    }

    private func metadataActionTitle(for path: String, hasMetadata: Bool) -> String {
        if vm.isEmbeddableAudioFile(path) {
            return hasMetadata ? "Edit Audio Tags" : "Add Audio Tags"
        }

        return hasMetadata ? "Edit Metadata" : "Add Metadata"
    }

    // MARK: - Card wrapper (shared with Lightbox style)

    @ViewBuilder
    private func detailCard(title: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if let title {
                Text(title)
                    .font(.appIcon(11, weight: .medium))
                    .foregroundStyle(Color.appMuted)
            }
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                content()
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface.opacity(0.6))
            .cornerRadius(AppRadius.lg)
        }
    }

    // MARK: - Generation Info Grid (matches Lightbox)

    @ViewBuilder
    private func genInfoGrid(_ info: GenerationInfo) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppSpacing.md) {
            genInfoCell(title: "Model", value: info.model)
            genInfoCell(title: "Aspect Ratio", value: info.aspectRatio.rawValue)
        }
        if !info.timestamp.isEmpty {
            genInfoCell(title: "Timestamp", value: formatTimestamp(info.timestamp))
        }
    }

    @ViewBuilder
    private func genInfoCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(title)
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)
            Text(value)
                .font(.appIcon(13, weight: .medium))
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.md)
    }

    // MARK: - File Info Card

    @ViewBuilder
    private func fileInfoCard(_ meta: FileMetadata) -> some View {
        detailCard(title: "File Info") {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                fileInfoRow(label: "Type", value: meta.fileType)
            if let w = meta.width, let h = meta.height {
                fileInfoRow(label: "Dimensions", value: "\(w) x \(h)")
            }
            if let duration = meta.duration {
                fileInfoRow(label: "Duration", value: formatDuration(duration))
            }
            if let date = meta.modifiedDate {
                fileInfoRow(label: "Modified", value: date.formatted(date: .abbreviated, time: .shortened))
            }
                if let size = meta.fileSize {
                    fileInfoRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
            }
        }
    }

    @ViewBuilder
    private func embeddedMetadataCard(_ fields: [PromptMetadataField]) -> some View {
        detailCard(title: "Embedded Metadata") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        HStack(alignment: .top, spacing: AppSpacing.md) {
                            Text(field.label)
                                .font(.appIcon(11, weight: .medium))
                                .foregroundStyle(Color.appMuted)
                            Spacer()
                            Button {
                                ClipboardService.copyString(field.value)
                                vm.showToast("\(field.label) copied", type: .success)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.appCaption)
                            }
                            .buttonStyle(AppIconButtonStyle(width: 22, height: 22, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                            .help("Copy \(field.label)")
                            .accessibilityLabel("Copy \(field.label)")
                        }

                        Text(field.value)
                            .font(.appCaption)
                            .foregroundStyle(Color.appPrimaryText)
                            .textSelection(.enabled)
                    }

                    if index < fields.count - 1 {
                        Divider().background(Color.appBorder.opacity(0.5))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fileInfoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Text(label)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.appCaption)
                .foregroundStyle(Color.appPrimaryText)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func referenceImageThumbnail(_ image: NSImage, index: Int, fileName: String) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 60, height: 60)
            .clipped()
            .cornerRadius(AppRadius.sm)
            .contextMenu {
                Button("Copy Reference Image") {
                    ClipboardService.copyImage(image)
                    vm.showToast("Reference image copied", type: .success)
                }

                Button("Save Reference Image…") {
                    saveReferenceImage(image, index: index, fileName: fileName)
                }
            }
    }

    private func formatTimestamp(_ ts: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: ts) {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd, h:mm:ss a"
            return df.string(from: date)
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: ts) {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd, h:mm:ss a"
            return df.string(from: date)
        }
        return ts
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: duration) ?? "\(Int(duration.rounded()))s"
    }

    private func preparePreviewVideoPlayer(for url: URL) {
        let assetURL = (previewVideoPlayer.currentItem?.asset as? AVURLAsset)?.url.standardizedFileURL
        let targetURL = url.standardizedFileURL

        if assetURL != targetURL {
            previewVideoPlayer.replaceCurrentItem(with: AVPlayerItem(url: targetURL))
        }

        previewVideoPlayer.actionAtItemEnd = .pause
        previewVideoPlayer.pause()
    }

    private func clearPreviewVideoPlayer() {
        previewVideoPlayer.pause()
        previewVideoPlayer.replaceCurrentItem(with: nil)
    }

    private func saveReferenceImage(_ image: NSImage, index: Int, fileName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(exportBaseName(from: fileName))-reference-\(index + 1).png"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try writePNGImage(image, to: url)
            vm.showToast("Reference image saved", type: .success)
        } catch {
            vm.showToast("Failed to save reference image: \(error.localizedDescription)", type: .error)
        }
    }

    private func exportBaseName(from fileName: String) -> String {
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmedName.isEmpty ? "image" : trimmedName
        let baseName = (candidate as NSString).deletingPathExtension
        return baseName.isEmpty ? candidate : baseName
    }

    private func writePNGImage(_ image: NSImage, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        try pngData.write(to: url)
    }
}

// MARK: - Analysis Card (shared style between explorer sidebar and lightbox)

struct AnalysisCard: View {
    let label: String
    let key: String
    let value: String
    var onSaveSnippet: (() -> Void)?

    @State private var isExpanded = false

    /// Decorative tint for the card fill and stroke.
    private var accentColor: Color {
        Color.segment(forAnalysisKey: key) ?? .appMuted
    }

    /// Text-safe variant for the heading label and glyph.
    private var labelColor: Color {
        Color.segmentText(forAnalysisKey: key) ?? .appMuted
    }

    private var iconName: String {
        switch key {
        case "fullPrompt": return "text.alignleft"
        case "shortDescription": return "text.justify.left"
        case "subject": return "person.fill"
        case "subjectPose": return "bolt.fill"
        case "composition": return "mappin.and.ellipse"
        case "artStyle": return "paintbrush.fill"
        case "cameraSettings": return "camera.fill"
        case "lighting": return "sun.max.fill"
        case "colorPalette": return "paintpalette.fill"
        case "mood": return "face.smiling"
        default: return "doc.text"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: iconName)
                    .font(.appCaption)
                    .foregroundStyle(labelColor)
                Text(label)
                    .font(.appHeadline)
                    .foregroundStyle(labelColor)
                Spacer()
                if let onSaveSnippet {
                    Button(action: onSaveSnippet) {
                        Image(systemName: "text.badge.star")
                            .font(.appCaption)
                    }
                    .buttonStyle(AppIconButtonStyle(width: 22, height: 22, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                    .help("Save Segment as Snippet")
                    .accessibilityLabel("Save \(label) as Snippet")
                }
                Button {
                    ClipboardService.copyString(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.appCaption)
                }
                .buttonStyle(AppIconButtonStyle(width: 22, height: 22, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                .help("Copy \(label)")
                .accessibilityLabel("Copy \(label)")
            }
            Text(value)
                .font(.appBody)
                .foregroundStyle(Color.appPrimaryText.opacity(0.85))
                .lineLimit(isExpanded ? nil : 3)
                .textSelection(.enabled)
                .onTapGesture { isExpanded.toggle() }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.appSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .fill(accentColor.opacity(0.14))
                }
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(accentColor.opacity(0.22), lineWidth: 1)
        )
    }
}

// MARK: - ComfyUI Workflow

/// Copy / save actions for the raw ComfyUI graphs embedded in a PNG, plus a
/// node-count summary parsed once per file.
private struct ComfyWorkflowSection: View {
    @Environment(ExplorerViewModel.self) private var vm
    let entry: PromptEntry

    @State private var summary: String?

    /// The UI workflow loads straight into ComfyUI; the API graph is the fallback.
    private var primaryJSON: String? { entry.comfyWorkflowJSON ?? entry.comfyPromptJSON }
    private var primaryKind: String { entry.comfyWorkflowJSON != nil ? "Workflow" : "API Prompt" }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.appCallout)
                    .foregroundStyle(Color.appAccent)
                Text(summary ?? "Embedded ComfyUI graph")
                    .font(.appCallout)
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(2)
            }

            HStack(spacing: AppSpacing.sm) {
                Button {
                    copy(primaryJSON, label: primaryKind)
                } label: {
                    Label("Copy \(primaryKind) JSON", systemImage: "doc.on.doc")
                        .font(.appCaption)
                }
                .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))

                Menu {
                    if let workflow = entry.comfyWorkflowJSON {
                        Button("Save Workflow as .json…") { save(workflow, suffix: "workflow") }
                    }
                    if let prompt = entry.comfyPromptJSON {
                        Button("Save API Prompt as .json…") { save(prompt, suffix: "api") }
                    }
                    if entry.comfyWorkflowJSON != nil, entry.comfyPromptJSON != nil {
                        Divider()
                        Button("Copy API Prompt JSON") { copy(entry.comfyPromptJSON, label: "API Prompt") }
                    }
                } label: {
                    Label("Save as .json…", systemImage: "square.and.arrow.down")
                        .font(.appCaption)
                } primaryAction: {
                    if let primaryJSON {
                        save(primaryJSON, suffix: entry.comfyWorkflowJSON != nil ? "workflow" : "api")
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Color.appMuted)
            }
        }
        .task(id: entry.sourcePath) {
            let workflow = entry.comfyWorkflowJSON
            let prompt = entry.comfyPromptJSON
            summary = await Task.detached(priority: .utility) {
                Self.summarize(workflowJSON: workflow, promptJSON: prompt)
            }.value
        }
    }

    private func copy(_ json: String?, label: String) {
        guard let json else { return }
        ClipboardService.copyString(json)
        vm.showToast("ComfyUI \(label) JSON copied", type: .success)
    }

    private func save(_ json: String, suffix: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let base = ((entry.fileMetadata?.fileName ?? entry.sourcePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "comfyui") as NSString)
            .deletingPathExtension
        panel.nameFieldStringValue = "\(base)-\(suffix).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(Self.prettyPrinted(json).utf8).write(to: url, options: .atomic)
            vm.showToast("Saved \(url.lastPathComponent)", type: .success)
        } catch {
            vm.showToast("Couldn't save JSON: \(error.localizedDescription)", type: .error)
        }
    }

    nonisolated private static func prettyPrinted(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8)
        else { return json }
        return string
    }

    /// "12 nodes · KSampler, CheckpointLoaderSimple, …" from either graph shape.
    nonisolated private static func summarize(workflowJSON: String?, promptJSON: String?) -> String? {
        var classTypes: [String] = []
        if let workflowJSON, let data = workflowJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let nodes = object["nodes"] as? [[String: Any]] {
            classTypes = nodes.compactMap { $0["type"] as? String }
        } else if let promptJSON, let data = promptJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            classTypes = object.values.compactMap { ($0 as? [String: Any])?["class_type"] as? String }
        }
        guard !classTypes.isEmpty else { return nil }

        let samplers = classTypes.filter { $0.localizedCaseInsensitiveContains("sampler") }.count
        let loras = classTypes.filter { $0.localizedCaseInsensitiveContains("lora") }.count
        var parts = ["\(classTypes.count) node\(classTypes.count == 1 ? "" : "s")"]
        if samplers > 0 { parts.append("\(samplers) sampler\(samplers == 1 ? "" : "s")") }
        if loras > 0 { parts.append("\(loras) LoRA loader\(loras == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Reusable Components (kept for backward compat if needed elsewhere)

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.appCaptionEmphasis)
            .foregroundStyle(Color.appMuted)
            .textCase(.uppercase)
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Text(label)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.appCaption)
                .foregroundStyle(Color.appPrimaryText)
                .textSelection(.enabled)
        }
    }
}
