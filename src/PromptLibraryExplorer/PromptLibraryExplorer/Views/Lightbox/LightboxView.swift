import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Full-screen lightbox overlay:
/// - Left: image filling edge-to-edge on a black background
/// - Right: scrollable details sidebar with card-style sections
/// - Overlaid on the main window (not a sheet)
struct LightboxView: View {
    @Environment(ExplorerViewModel.self) private var vm

    @State private var currentImageIndex = 0
    @State private var zoomScale: CGFloat = 1
    @State private var magnificationStartScale: CGFloat?
    @State private var imageOffset: CGSize = .zero
    @State private var dragStartImageOffset: CGSize?
    @State private var isHoveringViewport = false
    @State private var viewportSize: CGSize = .zero
    @State private var isHandToolEnabled = true
    @State private var videoPlayer = AVPlayer()
    @State private var isVideoPictureInPictureActive = false

    private let detailsSidebarWidth: CGFloat = 320
    private let viewportPadding: CGFloat = 18
    private let minimumZoomScale: CGFloat = 1
    private let maximumControlZoomScale: CGFloat = 4
    private let zoomStep: CGFloat = 0.25

    private var currentItem: FileEntry? {
        guard vm.lightboxIndex >= 0, vm.lightboxIndex < vm.processedFolderContents.count else { return nil }
        return vm.processedFolderContents[vm.lightboxIndex]
    }

    private var currentEntry: PromptEntry? {
        vm.selectedPromptEntry
    }

    private var currentImage: NSImage? {
        guard let entry = currentEntry, currentImageIndex >= 0, currentImageIndex < entry.images.count else { return nil }
        return entry.images[currentImageIndex]
    }

    private var currentVideoURL: URL? {
        currentEntry?.videoURL
    }

    private var currentAudioURL: URL? {
        currentEntry?.audioURL
    }

    private var canPanImage: Bool {
        isHandToolEnabled && zoomScale > 1.01
    }

    private var zoomPercentLabel: String {
        "\(Int((zoomScale * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: 0) {
            lightboxViewport
            detailsSidebar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appCanvasBackground)
        .compositingGroup()
        .onGlobalKeyDown { event in
            // Only handle when lightbox is open
            guard vm.lightboxOpen else { return false }
            // Save panels, sheets, other key windows (Settings) and focused text fields own their keys.
            guard !ModalKeyGuard.shouldIgnore(event) else { return false }
            if handleZoomShortcut(event) { return true }
            switch event.keyCode {
            case KeyCode.escape.rawValue:
                closeLightbox()
                return true
            case KeyCode.space.rawValue:
                if currentVideoURL != nil {
                    toggleVideoPlayback()
                } else if currentAudioURL != nil {
                    toggleAudioPlayback()
                } else {
                    closeLightbox()
                }
                return true
            case KeyCode.leftArrow.rawValue:
                navigateToPrevious()
                return true
            case KeyCode.rightArrow.rawValue:
                navigateToNext()
                return true
            default:
                return false
            }
        }
        .onGlobalScrollWheel { event in
            handleViewportScroll(event)
        }
        .onChange(of: vm.processedFolderContents.map(\.id)) { _, _ in
            reconcileLightboxIndexWithContents()
        }
        .onChange(of: vm.lightboxIndex) { _, _ in
            currentImageIndex = 0
            resetViewport(animated: false)
        }
        .onChange(of: currentImageIndex) { _, _ in
            resetViewport(animated: false)
        }
        .task(id: currentMediaTaskKey) {
            syncVideoPlayer()
        }
        .onDisappear {
            if !isVideoPictureInPictureActive {
                clearVideoPlayer()
            }
        }
    }

    // MARK: - Viewport

    @ViewBuilder
    private var lightboxViewport: some View {
        GeometryReader { geometry in
            ZStack {
                Color.appCanvasBackground

                if let image = currentImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoomScale)
                        .offset(imageOffset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(viewportPadding)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(for: image, viewportSize: geometry.size))
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    if magnificationStartScale == nil {
                                        magnificationStartScale = zoomScale
                                    }

                                    let startScale = magnificationStartScale ?? zoomScale
                                    setZoomScale(startScale * value, for: image, viewportSize: geometry.size)
                                }
                                .onEnded { _ in
                                    magnificationStartScale = nil
                                    imageOffset = clampedOffset(imageOffset, for: image, viewportSize: geometry.size, zoomScale: zoomScale)
                                }
                        )
                        .onTapGesture(count: 2) {
                            toggleZoom(for: image, viewportSize: geometry.size)
                        }
                } else if currentVideoURL != nil {
                    VideoPlayerSurface(
                        player: videoPlayer,
                        isPictureInPictureActive: $isVideoPictureInPictureActive
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(viewportPadding)
                } else if currentAudioURL != nil {
                    AudioPlayerView(player: videoPlayer, fileName: currentItem?.name ?? "Audio")
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(viewportPadding)
                }

                HStack {
                    navArrow(systemName: "chevron.left", label: "Previous Item") { navigateToPrevious() }
                    Spacer()
                    navArrow(systemName: "chevron.right", label: "Next Item") { navigateToNext() }
                }
                .padding(.horizontal, AppSpacing.lg)

                if let entry = currentEntry, entry.images.count > 1 {
                    VStack {
                        Spacer()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: AppSpacing.sm) {
                                ForEach(Array(entry.images.enumerated()), id: \.offset) { idx, img in
                                    Image(nsImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 48, height: 48)
                                        .clipped()
                                        .cornerRadius(AppRadius.xs)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: AppRadius.xs)
                                                .strokeBorder(
                                                    idx == currentImageIndex ? Color.appAccent : Color.clear,
                                                    lineWidth: 2
                                                )
                                        )
                                        .onTapGesture { currentImageIndex = idx }
                                }
                            }
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, AppSpacing.md)
                        }
                        .background(Color.appOverlaySurface)
                    }
                }

                if let image = currentImage {
                    zoomToolbar(for: image, viewportSize: geometry.size)
                        .padding(.bottom, (currentEntry?.images.count ?? 0) > 1 ? 82 : 28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .opacity(isHoveringViewport ? 1 : 0)
                        .allowsHitTesting(isHoveringViewport)
                        .animation(.easeInOut(duration: 0.14), value: isHoveringViewport)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringViewport = hovering
            }
            .onAppear {
                viewportSize = geometry.size
            }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: - Details Sidebar

    @ViewBuilder
    private var detailsSidebar: some View {
        VStack(spacing: 0) {
            // Close button row
            HStack {
                Text("Details")
                    .font(.appIcon(16, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
                Button { closeLightbox() } label: {
                    Image(systemName: "xmark")
                        .font(.appIcon(14, weight: .medium))
                        .foregroundStyle(Color.appPrimaryText.opacity(0.9))
                        .frame(width: 30, height: 30)
                        .background(Color.appElevatedSurface, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.md)
                                .strokeBorder(Color.appControlBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(AppAdaptiveButtonStyle())
                .help("Close (Esc)")
                .accessibilityLabel("Close Lightbox")
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.lg)

            Divider().background(Color.appBorder)

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    if let entry = vm.selectedPromptEntry {
                        // File Name card
                        if let item = currentItem {
                            cardSection(title: "File Name") {
                                Text(item.name)
                                    .font(.appBody)
                                    .foregroundStyle(Color.appPrimaryText)
                                    .textSelection(.enabled)
                            }
                        }

                        if let meta = entry.fileMetadata {
                            cardSection(title: "File Info") {
                                fileInfoRows(meta)
                            }
                        }

                        if !entry.embeddedMetadata.isEmpty {
                            cardSection(title: "Embedded Metadata") {
                                embeddedMetadataFields(entry.embeddedMetadata)
                            }
                        }

                        // Prompt card
                        if !entry.prompt.isEmpty {
                            cardSection(title: nil) {
                                HStack(alignment: .top, spacing: AppSpacing.sm) {
                                    Image(systemName: "text.quote")
                                        .font(.appCallout)
                                        .foregroundStyle(Color.appAccent)
                                    Text("Prompt")
                                        .font(.appHeadline)
                                        .foregroundStyle(Color.appPrimaryText)
                                    Spacer()
                                    copyButton(entry.prompt)
                                }
                                Text(entry.prompt)
                                    .font(.appBody)
                                    .foregroundStyle(Color.appPrimaryText.opacity(0.9))
                                    .textSelection(.enabled)
                                    .padding(.top, AppSpacing.xs)
                            }
                        }

                        // Generation Info card
                        if entry.generationInfo.model != "N/A" {
                            cardSection(title: "Generation Info") {
                                genInfoGrid(entry.generationInfo)
                            }
                        }

                        // Reference Images
                        if !entry.referenceImages.isEmpty {
                            cardSection(title: "Reference Images") {
                                HStack(spacing: AppSpacing.md) {
                                    ForEach(Array(entry.referenceImages.enumerated()), id: \.offset) { index, img in
                                        referenceImageThumbnail(
                                            img,
                                            index: index,
                                            fileName: currentItem?.name ?? entry.fileMetadata?.fileName ?? "image"
                                        )
                                    }
                                }
                            }
                        }

                        // Analysis segments
                        if let analysis = entry.analysis {
                            let segments = analysis.segments
                            if !segments.isEmpty {
                                ForEach(segments, id: \.key) { seg in
                                    LightboxAnalysisCard(
                                        label: seg.label,
                                        key: seg.key,
                                        value: seg.value,
                                        onSaveSnippet: {
                                            let text = seg.value.trimmingCharacters(in: .whitespacesAndNewlines)
                                            guard !text.isEmpty else { return }
                                            SnippetService.shared.add(title: seg.label, text: text, category: seg.label)
                                            vm.showToast("Saved \(seg.label) as a snippet", type: .success)
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.xl)
                .padding(.vertical, AppSpacing.md)
            }

            Divider().background(Color.appBorder)

            // Bottom action buttons
            if let entry = vm.selectedPromptEntry {
                VStack(spacing: AppSpacing.md) {
                    if entry.videoURL != nil {
                        actionButton(icon: "arrow.down.circle", label: "Save Video") {
                            saveCurrentVideo(entry: entry)
                        }
                    } else if !entry.images.isEmpty {
                        actionButton(
                            icon: "arrow.down.circle",
                            label: "Save Image (\(currentImageIndex + 1) of \(entry.images.count))"
                        ) {
                            saveCurrentImage(entry: entry)
                        }
                    }

                    if FileHelpers.isPlibFile(currentItem?.name ?? "") {
                        actionButton(icon: "arrow.down.circle", label: "Save .plib") {
                            savePlibFile()
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.xl)
                .padding(.vertical, AppSpacing.lg)
            }
        }
        .frame(width: detailsSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Color.appSidebarBackground)
        .overlay(alignment: .leading) {
            Divider()
                .background(Color.appBorder)
        }
        .zIndex(2)
    }

    // MARK: - Card Section

    @ViewBuilder
    private func cardSection(title: String?, @ViewBuilder content: () -> some View) -> some View {
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

    // MARK: - Generation Info Grid

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
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.md)
    }

    @ViewBuilder
    private func fileInfoRows(_ meta: FileMetadata) -> some View {
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
    private func embeddedMetadataFields(_ fields: [PromptMetadataField]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    HStack(alignment: .top, spacing: AppSpacing.md) {
                        Text(field.label)
                            .font(.appIcon(11, weight: .medium))
                            .foregroundStyle(Color.appMuted)
                        Spacer()
                        copyButton(field.value)
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

    // MARK: - Helpers

    @ViewBuilder
    private func navArrow(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.appLargeTitle)
                .foregroundStyle(Color.appPrimaryText)
                .frame(width: 40, height: 40)
                .background(Color.appOverlaySurface.opacity(0.75), in: Circle())
        }
        .buttonStyle(AppAdaptiveButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func copyButton(_ text: String) -> some View {
        Button {
            ClipboardService.copyString(text)
            vm.showToast("Copied", type: .success)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.appCaption)
        }
        .buttonStyle(AppIconButtonStyle(width: 22, height: 22, cornerRadius: AppRadius.sm, showsRestingChrome: false))
        .help("Copy")
        .accessibilityLabel("Copy")
    }

    @ViewBuilder
    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon)
                    .font(.appBody)
                Text(label)
                    .font(.appIcon(13, weight: .medium))
            }
            .foregroundStyle(Color.appPrimaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.appElevatedSurface)
            .cornerRadius(AppRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .strokeBorder(Color.appControlBorder, lineWidth: 1)
            )
        }
        .buttonStyle(AppAdaptiveButtonStyle())
    }

    @ViewBuilder
    private func zoomToolbar(for image: NSImage, viewportSize: CGSize) -> some View {
        HStack(spacing: 10) {
            zoomToolbarButton(systemName: "magnifyingglass.minus", label: "Zoom Out", isActive: false) {
                adjustZoom(by: -zoomStep, for: image, viewportSize: viewportSize, animated: true)
            }
            .disabled(zoomScale <= minimumZoomScale + 0.001)

            Slider(
                value: Binding(
                    get: { Double(zoomScale) },
                    set: { newValue in
                        setZoomScale(CGFloat(newValue), for: image, viewportSize: viewportSize)
                    }
                ),
                in: Double(minimumZoomScale)...Double(maximumControlZoomScale),
                step: 0.01
            )
            .frame(width: 170)
            .tint(Color.appPrimaryText)
            .accessibilityLabel("Zoom")
            .accessibilityValue(zoomPercentLabel)

            Text(zoomPercentLabel)
                .font(.appCalloutEmphasis)
                .foregroundStyle(Color.appPrimaryText)
                .frame(minWidth: 42)

            zoomToolbarButton(systemName: "magnifyingglass.plus", label: "Zoom In", isActive: false) {
                adjustZoom(by: zoomStep, for: image, viewportSize: viewportSize, animated: true)
            }
            .disabled(zoomScale >= maximumControlZoomScale - 0.001)

            Rectangle()
                .fill(Color.appOverlayDivider)
                .frame(width: 1, height: 18)

            zoomToolbarButton(
                systemName: isHandToolEnabled ? "hand.draw.fill" : "hand.draw",
                label: isHandToolEnabled ? "Disable Hand Tool" : "Enable Hand Tool",
                isActive: isHandToolEnabled
            ) {
                isHandToolEnabled.toggle()
                dragStartImageOffset = nil
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.appOverlaySurface, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.appOverlayStroke, lineWidth: 1)
        )
        .shadow(color: Color.appShadowColor, radius: 14, y: 6)
    }

    @ViewBuilder
    private func zoomToolbarButton(systemName: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isActive ? Color.appOverlayActiveFill : Color.clear)
                )
        }
        .buttonStyle(AppAdaptiveButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private func formatTimestamp(_ ts: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: ts) {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd, h:mm:ss a"
            return df.string(from: date)
        }
        // Try without fractional seconds
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

    private func handleZoomShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.control),
              let image = currentImage,
              viewportSize.width > 0,
              viewportSize.height > 0
        else {
            return false
        }

        switch event.charactersIgnoringModifiers ?? "" {
        case "=", "+":
            adjustZoom(by: zoomStep, for: image, viewportSize: viewportSize, animated: true)
            return true
        case "-", "_":
            adjustZoom(by: -zoomStep, for: image, viewportSize: viewportSize, animated: true)
            return true
        default:
            return false
        }
    }

    private func handleViewportScroll(_ event: NSEvent) -> Bool {
        guard vm.lightboxOpen,
              isHoveringViewport,
              let image = currentImage,
              viewportSize.width > 0,
              viewportSize.height > 0
        else {
            return false
        }

        if event.modifierFlags.contains(.command) {
            return handleViewportZoomScroll(event, image: image)
        }

        return handleViewportPanScroll(event, image: image)
    }

    private func handleViewportZoomScroll(_ event: NSEvent, image: NSImage) -> Bool {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return false }

        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.006 : 0.14
        let proposedScale = zoomScale + (CGFloat(event.scrollingDeltaY) * sensitivity)
        guard abs(proposedScale - zoomScale) > 0.0001 else { return false }

        setZoomScale(proposedScale, for: image, viewportSize: viewportSize)
        return true
    }

    private func handleViewportPanScroll(_ event: NSEvent, image: NSImage) -> Bool {
        guard zoomScale > 1.01 else { return false }

        let deltaMultiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 18
        var horizontalDelta = CGFloat(event.scrollingDeltaX) * deltaMultiplier
        var verticalDelta = CGFloat(event.scrollingDeltaY) * deltaMultiplier

        if abs(horizontalDelta) < 0.001, event.modifierFlags.contains(.shift) {
            horizontalDelta = verticalDelta
            verticalDelta = 0
        }

        let proposedOffset = CGSize(
            width: imageOffset.width + horizontalDelta,
            height: imageOffset.height + verticalDelta
        )
        let nextOffset = clampedOffset(
            proposedOffset,
            for: image,
            viewportSize: viewportSize,
            zoomScale: zoomScale
        )

        guard abs(nextOffset.width - imageOffset.width) > 0.0001 ||
                abs(nextOffset.height - imageOffset.height) > 0.0001
        else {
            return false
        }

        dragStartImageOffset = nil
        imageOffset = nextOffset
        return true
    }

    private func closeLightbox() {
        resetViewport(animated: false)
        vm.lightboxOpen = false

        if !isVideoPictureInPictureActive {
            clearVideoPlayer()
        }
    }

    // MARK: - Navigation

    private func navigateToPrevious() {
        guard !isVideoPictureInPictureActive else {
            vm.showToast("Stop Picture in Picture before switching items", type: .info)
            return
        }
        let items = vm.processedFolderContents
        guard !items.isEmpty else { return }
        // Clamp: the contents may have shrunk while the lightbox was open.
        var idx = min(vm.lightboxIndex, items.count) - 1
        while idx >= 0 {
            if FileHelpers.isPreviewable(items[idx]) {
                vm.lightboxIndex = idx
                vm.selectItem(at: idx)
                return
            }
            idx -= 1
        }
    }

    private func navigateToNext() {
        guard !isVideoPictureInPictureActive else {
            vm.showToast("Stop Picture in Picture before switching items", type: .info)
            return
        }
        let items = vm.processedFolderContents
        guard !items.isEmpty else { return }
        var idx = max(vm.lightboxIndex + 1, 0)
        while idx < items.count {
            if FileHelpers.isPreviewable(items[idx]) {
                vm.lightboxIndex = idx
                vm.selectItem(at: idx)
                return
            }
            idx += 1
        }
    }

    /// Keeps the lightbox pointing at a valid item after the folder contents change
    /// underneath it (navigate back, undo, refresh). Closes it when nothing is left.
    private func reconcileLightboxIndexWithContents() {
        guard vm.lightboxOpen else { return }
        let items = vm.processedFolderContents
        guard !items.isEmpty else {
            closeLightbox()
            return
        }
        guard vm.lightboxIndex < 0 || vm.lightboxIndex >= items.count else { return }

        let start = min(max(vm.lightboxIndex, 0), items.count - 1)
        let candidates = Array((0...start).reversed()) + Array((start + 1)..<items.count)
        guard let idx = candidates.first(where: { FileHelpers.isPreviewable(items[$0]) }) else {
            closeLightbox()
            return
        }
        vm.lightboxIndex = idx
        vm.selectItem(at: idx)
    }

    private func dragGesture(for image: NSImage, viewportSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: canPanImage ? 0 : 12)
            .onChanged { value in
                guard canPanImage else { return }
                if dragStartImageOffset == nil {
                    dragStartImageOffset = imageOffset
                }

                let startOffset = dragStartImageOffset ?? imageOffset
                let proposedOffset = CGSize(
                    width: startOffset.width + value.translation.width,
                    height: startOffset.height + value.translation.height
                )
                imageOffset = clampedOffset(proposedOffset, for: image, viewportSize: viewportSize, zoomScale: zoomScale)
            }
            .onEnded { _ in
                dragStartImageOffset = nil
            }
    }

    private func clampedOffset(_ proposedOffset: CGSize, for image: NSImage, viewportSize: CGSize, zoomScale: CGFloat) -> CGSize {
        guard zoomScale > 1.0001 else { return .zero }

        let availableSize = CGSize(
            width: max(viewportSize.width - (viewportPadding * 2), 1),
            height: max(viewportSize.height - (viewportPadding * 2), 1)
        )
        let fittedSize = fittedImageSize(for: image.size, in: availableSize)
        let scaledSize = CGSize(width: fittedSize.width * zoomScale, height: fittedSize.height * zoomScale)
        let maxOffsetX = max((scaledSize.width - availableSize.width) / 2, 0)
        let maxOffsetY = max((scaledSize.height - availableSize.height) / 2, 0)

        return CGSize(
            width: min(max(proposedOffset.width, -maxOffsetX), maxOffsetX),
            height: min(max(proposedOffset.height, -maxOffsetY), maxOffsetY)
        )
    }

    private func fittedImageSize(for imageSize: NSSize, in availableSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(availableSize.width / imageSize.width, availableSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func clampedZoomScale(_ proposedScale: CGFloat) -> CGFloat {
        min(max(proposedScale, minimumZoomScale), maximumControlZoomScale)
    }

    private func setZoomScale(_ proposedScale: CGFloat, for image: NSImage, viewportSize: CGSize, animated: Bool = false) {
        let nextScale = clampedZoomScale(proposedScale)
        let updates = {
            zoomScale = nextScale
            imageOffset = clampedOffset(imageOffset, for: image, viewportSize: viewportSize, zoomScale: nextScale)
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.18), updates)
        } else {
            updates()
        }
    }

    private func adjustZoom(by delta: CGFloat, for image: NSImage, viewportSize: CGSize, animated: Bool = false) {
        setZoomScale(zoomScale + delta, for: image, viewportSize: viewportSize, animated: animated)
    }

    private func toggleZoom(for image: NSImage, viewportSize: CGSize) {
        if zoomScale > 1.0001 {
            setZoomScale(minimumZoomScale, for: image, viewportSize: viewportSize, animated: true)
        } else {
            setZoomScale(maximumControlZoomScale, for: image, viewportSize: viewportSize, animated: true)
        }
    }

    private func resetViewport(animated: Bool) {
        let updates = {
            zoomScale = 1
            magnificationStartScale = nil
            imageOffset = .zero
            dragStartImageOffset = nil
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.18), updates)
        } else {
            updates()
        }
    }

    private var currentMediaTaskKey: String {
        let itemPath = currentItem?.path ?? "nil"
        let videoPath = currentVideoURL?.standardizedFileURL.path ?? "nil"
        let audioPath = currentAudioURL?.standardizedFileURL.path ?? "nil"
        return "\(itemPath)|\(videoPath)|\(audioPath)"
    }

    private func syncVideoPlayer() {
        // Handle audio files
        if let audioURL = currentAudioURL {
            let targetURL = audioURL.standardizedFileURL
            let currentAssetURL = (videoPlayer.currentItem?.asset as? AVURLAsset)?.url.standardizedFileURL

            if currentAssetURL != targetURL {
                videoPlayer.replaceCurrentItem(with: AVPlayerItem(url: targetURL))
            }

            videoPlayer.actionAtItemEnd = .pause
            videoPlayer.play()
            return
        }

        guard let videoURL = currentVideoURL else {
            if !isVideoPictureInPictureActive {
                clearVideoPlayer()
            }
            return
        }

        let targetURL = videoURL.standardizedFileURL
        let currentAssetURL = (videoPlayer.currentItem?.asset as? AVURLAsset)?.url.standardizedFileURL

        if isVideoPictureInPictureActive, currentAssetURL != targetURL {
            return
        }

        if currentAssetURL != targetURL {
            videoPlayer.replaceCurrentItem(with: AVPlayerItem(url: targetURL))
        }

        videoPlayer.actionAtItemEnd = .pause
        videoPlayer.play()
    }

    private func clearVideoPlayer() {
        videoPlayer.pause()
        videoPlayer.replaceCurrentItem(with: nil)
        isVideoPictureInPictureActive = false
    }

    private func toggleVideoPlayback() {
        guard currentVideoURL != nil else { return }

        if videoPlayer.timeControlStatus == .playing {
            videoPlayer.pause()
        } else {
            syncVideoPlayer()
        }
    }

    private func toggleAudioPlayback() {
        guard currentAudioURL != nil else { return }

        if videoPlayer.timeControlStatus == .playing {
            videoPlayer.pause()
        } else {
            syncVideoPlayer()
        }
    }

    // MARK: - Save Actions

    private func saveCurrentImage(entry: PromptEntry) {
        guard currentImageIndex < entry.images.count else { return }
        let image = entry.images[currentImageIndex]

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = currentItem?.name ?? "image.png"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ext = url.pathExtension.lowercased()
        let fileType: NSBitmapImageRep.FileType = (ext == "jpg" || ext == "jpeg") ? .jpeg : .png

        do {
            try writeImage(image, as: fileType, to: url)
            vm.showToast("Image saved", type: .success)
        } catch {
            vm.showToast("Failed to save image: \(error.localizedDescription)", type: .error)
        }
    }

    private func saveCurrentVideo(entry: PromptEntry) {
        guard let videoURL = entry.videoURL else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: videoURL.pathExtension)].compactMap { $0 }
        panel.nameFieldStringValue = currentItem?.name ?? videoURL.lastPathComponent
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: videoURL, to: destURL)
            vm.showToast("Video saved", type: .success)
        } catch {
            vm.showToast("Failed to save video: \(error.localizedDescription)", type: .error)
        }
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

    private func savePlibFile() {
        guard let item = currentItem else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        // Saving over the source file itself is a no-op.
        if destURL.standardizedFileURL.path == item.url.standardizedFileURL.path {
            vm.showToast(".plib saved", type: .success)
            return
        }

        do {
            // copyItem refuses to overwrite; the save panel already confirmed replacement.
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: item.url, to: destURL)
            vm.showToast(".plib saved", type: .success)
        } catch {
            vm.showToast("Failed to save .plib: \(error.localizedDescription)", type: .error)
        }
    }

    private func exportBaseName(from fileName: String) -> String {
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmedName.isEmpty ? "image" : trimmedName
        let baseName = (candidate as NSString).deletingPathExtension
        return baseName.isEmpty ? candidate : baseName
    }

    private func writePNGImage(_ image: NSImage, to url: URL) throws {
        try writeImage(image, as: .png, to: url)
    }

    private func writeImage(_ image: NSImage, as fileType: NSBitmapImageRep.FileType, to url: URL) throws {
        let properties: [NSBitmapImageRep.PropertyKey: Any] =
            fileType == .jpeg ? [.compressionFactor: 0.92] : [:]
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: fileType, properties: properties)
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Analysis Card (icon + colored label + copy button)

struct LightboxAnalysisCard: View {
    let label: String
    let key: String
    let value: String
    var onSaveSnippet: (() -> Void)?

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
                .textSelection(.enabled)
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
