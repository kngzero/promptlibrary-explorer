import SwiftUI

struct MetadataPanelView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var previewPaneRatio: CGFloat = 0.42
    @State private var dragStartPreviewRatio: CGFloat?

    private let dividerHeight: CGFloat = 12
    private let minimumPreviewHeight: CGFloat = 150
    private let minimumMetadataHeight: CGFloat = 220

    var body: some View {
        Group {
            if let entry = vm.selectedPromptEntry {
                VStack(spacing: 0) {
                    HStack {
                        Text("Details")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.appPrimaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
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
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.appMuted.opacity(0.5))
                    Text("Select an item to view details")
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.appSidebarBackground)
    }

    @ViewBuilder
    private func detailSplitView(entry: PromptEntry, availableHeight: CGFloat) -> some View {
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

    @ViewBuilder
    private func previewPane(entry: PromptEntry) -> some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.appSurface.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.appBorder, lineWidth: 1)
                    )

                if let firstImage = entry.images.first {
                    Image(nsImage: firstImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(12)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.appMuted.opacity(0.7))
                        Text("No preview available")
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func metadataPane(entry: PromptEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !entry.prompt.isEmpty {
                    detailCard(title: nil) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "text.quote")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.appAccent)
                            Text("Prompt")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.appPrimaryText)
                            Spacer()
                            PromptExportMenu(entry: entry) { formatName in
                                vm.showToast("Copied as \(formatName)", type: .success)
                            }
                            Button {
                                ClipboardService.copyString(entry.prompt)
                                vm.showToast("Prompt copied", type: .success)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.appMuted)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(entry.prompt)
                            .font(.appBody)
                            .foregroundStyle(Color.appPrimaryText.opacity(0.9))
                            .textSelection(.enabled)
                            .padding(.top, 4)
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

                    // Star Rating
                    if let path = entry.sourcePath {
                        HStack {
                            Text("Rating")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.appMuted)
                            Spacer()
                            StarRatingView(rating: vm.rating(for: path), size: 16) { newRating in
                                vm.setRating(newRating, for: path)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }

                    fileInfoCard(meta)

                    if !entry.embeddedMetadata.isEmpty {
                        embeddedMetadataCard(entry.embeddedMetadata)
                    }
                }

                if !entry.referenceImages.isEmpty {
                    detailCard(title: "Reference Images") {
                        HStack(spacing: 8) {
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
                                value: seg.value
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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

    // MARK: - Card wrapper (shared with Lightbox style)

    @ViewBuilder
    private func detailCard(title: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appMuted)
            }
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface.opacity(0.6))
            .cornerRadius(10)
        }
    }

    // MARK: - Generation Info Grid (matches Lightbox)

    @ViewBuilder
    private func genInfoGrid(_ info: GenerationInfo) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            genInfoCell(title: "Model", value: info.model)
            genInfoCell(title: "Aspect Ratio", value: info.aspectRatio.rawValue)
        }
        if !info.timestamp.isEmpty {
            genInfoCell(title: "Timestamp", value: formatTimestamp(info.timestamp))
        }
    }

    @ViewBuilder
    private func genInfoCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Color.appMuted)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface)
        .cornerRadius(8)
    }

    // MARK: - File Info Card

    @ViewBuilder
    private func fileInfoCard(_ meta: FileMetadata) -> some View {
        detailCard(title: "File Info") {
            VStack(alignment: .leading, spacing: 4) {
                fileInfoRow(label: "Type", value: meta.fileType)
                if let w = meta.width, let h = meta.height {
                    fileInfoRow(label: "Dimensions", value: "\(w) x \(h)")
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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            Text(field.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.appMuted)
                            Spacer()
                            Button {
                                ClipboardService.copyString(field.value)
                                vm.showToast("\(field.label) copied", type: .success)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.appMuted)
                            }
                            .buttonStyle(.plain)
                        }

                        Text(field.value)
                            .font(.system(size: 11))
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
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.appMuted)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
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
            .cornerRadius(6)
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

    @State private var isExpanded = false

    private var accentColor: Color {
        switch key {
        case "fullPrompt": return .segmentFullPrompt
        case "shortDescription": return .segmentBrief
        case "subject": return .segmentSubject
        case "subjectPose": return .segmentAction
        case "composition": return .segmentPlace
        case "artStyle": return .segmentStyle
        case "cameraSettings": return .segmentCamera
        case "lighting": return .segmentLighting
        case "colorPalette": return .segmentPalette
        case "mood": return .segmentMood
        default: return .appMuted
        }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(accentColor)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentColor)
                Spacer()
                Button {
                    ClipboardService.copyString(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appMuted)
                }
                .buttonStyle(.plain)
            }
            Text(value)
                .font(.appBody)
                .foregroundStyle(Color.appPrimaryText.opacity(0.85))
                .lineLimit(isExpanded ? nil : 3)
                .textSelection(.enabled)
                .onTapGesture { isExpanded.toggle() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.appSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(accentColor.opacity(0.14))
                }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accentColor.opacity(0.22), lineWidth: 1)
        )
    }
}

// MARK: - Reusable Components (kept for backward compat if needed elsewhere)

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.appMuted)
            .textCase(.uppercase)
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
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
