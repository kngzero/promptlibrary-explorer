import AppKit
import SwiftUI

/// Edits every setting of an export preset. Shared by the export sheet and
/// Settings ▸ Export.
struct ExportPresetEditorView: View {
    @Binding var preset: ExportPreset
    /// Shown in the watermark preview instead of the built-in sample, when set.
    var sampleURL: URL?
    var showsName = true

    private let labelWidth: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            if showsName {
                section("Preset") {
                    row("Name") {
                        TextField("Preset name", text: $preset.name)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Preset name")
                    }
                }
            }
            formatSection
            sizeSection
            metadataSection
            namingSection
            watermarkSection
            otherFilesSection
        }
    }

    // MARK: Format & size

    private var formatSection: some View {
        section("Format") {
            row("Format") {
                Picker("Format", selection: $preset.format) {
                    ForEach(formatChoices) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if preset.format.usesQuality {
                row(preset.format == .keepOriginal ? "Quality (lossy)" : "Quality") {
                    HStack(spacing: AppSpacing.md) {
                        Slider(value: $preset.quality, in: 0.1...1)
                            .frame(maxWidth: 220)
                            .accessibilityLabel("Quality")
                        Text("\(Int((preset.quality * 100).rounded()))")
                            .font(.appMono)
                            .foregroundStyle(Color.appMuted)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
            row("Colour profile") {
                Picker("Colour profile", selection: $preset.colorProfile) {
                    ForEach(ExportColorProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if preset.format == .keepOriginal {
                hint("Each image keeps its own format. Formats this Mac can't write (such as WebP or GIF) become PNG. With Original Size and no watermark, pixels are left untouched.")
            }
        }
    }

    /// Available formats, plus the current one if it isn't (an old preset asking for WebP).
    private var formatChoices: [ExportFormat] {
        var choices = ExportFormat.availableCases
        if !choices.contains(preset.format) { choices.append(preset.format) }
        return choices
    }

    private var sizeSection: some View {
        section("Size") {
            row("Resize") {
                Picker("Resize", selection: $preset.sizing.mode) {
                    ForEach(ExportSizing.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            switch preset.sizing.mode {
            case .original:
                EmptyView()
            case .longEdge:
                row("Long edge") {
                    HStack(spacing: AppSpacing.md) {
                        NumberField(value: $preset.sizing.longEdge, range: 16...16384, label: "Long edge in pixels")
                        Text("px").font(.appCallout).foregroundStyle(Color.appMuted)
                    }
                }
                row("") {
                    SettingsToggleRow(title: "Enlarge smaller images", isOn: $preset.sizing.allowUpscale)
                }
            case .exact:
                row("Size") {
                    HStack(spacing: AppSpacing.md) {
                        NumberField(value: $preset.sizing.width, range: 1...16384, label: "Width in pixels")
                        Text("×").foregroundStyle(Color.appMuted)
                        NumberField(value: $preset.sizing.height, range: 1...16384, label: "Height in pixels")
                        Text("px").font(.appCallout).foregroundStyle(Color.appMuted)
                    }
                }
                hint("Scaled to fill, then centre-cropped to exactly this size.")
            case .scale:
                row("Scale") {
                    HStack(spacing: AppSpacing.md) {
                        Slider(value: $preset.sizing.scalePercent, in: 5...200, step: 5)
                            .frame(maxWidth: 220)
                            .accessibilityLabel("Scale percent")
                        Text("\(Int(preset.sizing.scalePercent.rounded()))%")
                            .font(.appMono)
                            .foregroundStyle(Color.appMuted)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: Metadata

    private var metadataSection: some View {
        section("Metadata") {
            SettingsChoiceRow(
                options: ExportMetadataPolicy.Mode.allCases,
                title: \.title,
                explanation: \.explanation,
                selection: $preset.metadata.mode
            )
            if preset.metadata.mode == .keepOnly {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    ForEach(ExportMetadataField.allCases) { field in
                        SettingsToggleRow(title: field.title, isOn: Binding(
                            get: { preset.metadata.keptFields.contains(field) },
                            set: { keep in
                                if keep { preset.metadata.keptFields.insert(field) } else { preset.metadata.keptFields.remove(field) }
                            }
                        ))
                    }
                }
                .padding(.leading, 22)
                if preset.metadata.keptFields.contains(.workflow) {
                    hint("A ComfyUI graph contains the prompt text too, and is only kept in PNG output.")
                }
            }
        }
    }

    // MARK: Naming & destination

    private var namingSection: some View {
        section("Name & Destination") {
            row("File name") {
                HStack(spacing: AppSpacing.md) {
                    TextField("{name}", text: $preset.filenameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.appMono)
                        .accessibilityLabel("File name template")
                    Menu {
                        ForEach(RenameTemplateService.tokens, id: \.token) { token in
                            Button("\(token.token) — \(token.description)") { insert(token.token) }
                        }
                    } label: {
                        Image(systemName: "curlybraces")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Insert a template token")
                    .accessibilityLabel("Insert template token")
                }
            }
            hint("Same tokens as Batch Rename. The output format's extension is added for you.")
            row("Save to") {
                Picker("Save to", selection: $preset.destination) {
                    ForEach(ExportDestinationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            switch preset.destination {
            case .ask:
                EmptyView()
            case .fixedFolder:
                row("Folder") {
                    HStack(spacing: AppSpacing.md) {
                        Text(preset.fixedFolderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None chosen")
                            .font(.appCallout)
                            .foregroundStyle(preset.fixedFolderPath == nil ? Color.appMuted : Color.appPrimaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseFixedFolder)
                    }
                }
            case .subfolder:
                row("Subfolder name") {
                    TextField("Exports", text: $preset.subfolderName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .accessibilityLabel("Subfolder name")
                }
            }
            row("If the name exists") {
                Picker("If the name exists", selection: $preset.collision) {
                    ForEach(ExportCollisionPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func insert(_ token: String) {
        let concrete: String
        switch token {
        case "{date:FORMAT}": concrete = "{date:yyyyMMdd}"
        case "{prompt:N}": concrete = "{prompt:40}"
        case "{counter:N}": concrete = "{counter:3}"
        default: concrete = token
        }
        let template = preset.filenameTemplate
        let separator = template.isEmpty || template.hasSuffix("_") || template.hasSuffix("-") || template.hasSuffix(" ") ? "" : "_"
        preset.filenameTemplate = template + separator + concrete
    }

    private func chooseFixedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Exports with this preset go into this folder."
        if let path = preset.fixedFolderPath { panel.directoryURL = URL(fileURLWithPath: path) }
        if panel.runModal() == .OK, let url = panel.url {
            preset.fixedFolderPath = url.path
        }
    }

    // MARK: Watermark

    private var watermarkSection: some View {
        section("Watermark") {
            SettingsToggleRow(title: "Add a watermark", isOn: $preset.watermark.isEnabled)
            if preset.watermark.isEnabled {
                row("Type") {
                    Picker("Type", selection: $preset.watermark.kind) {
                        ForEach(ExportWatermark.Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                switch preset.watermark.kind {
                case .text:
                    row("Text") {
                        TextField("© Your Name", text: $preset.watermark.text)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Watermark text")
                    }
                    row("Colour") {
                        HStack(spacing: AppSpacing.lg) {
                            ColorPicker("Colour", selection: textColorBinding, supportsOpacity: false)
                                .labelsHidden()
                                .accessibilityLabel("Watermark colour")
                            SettingsToggleRow(title: "Bold", isOn: $preset.watermark.bold)
                                .fixedSize()
                        }
                    }
                case .image:
                    row("Image") {
                        HStack(spacing: AppSpacing.md) {
                            Text(preset.watermark.imagePath.map { ($0 as NSString).lastPathComponent } ?? "None chosen")
                                .font(.appCallout)
                                .foregroundStyle(preset.watermark.imagePath == nil ? Color.appMuted : Color.appPrimaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…", action: chooseWatermarkImage)
                        }
                    }
                    hint("A PNG with transparency works best.")
                }
                row("Position") {
                    WatermarkPositionGrid(selection: $preset.watermark.position)
                }
                sliderRow("Size", value: $preset.watermark.scale, range: 0.03...0.8, format: { "\(Int(($0 * 100).rounded()))% of width" })
                sliderRow("Margin", value: $preset.watermark.margin, range: 0...0.2, format: { "\(Int(($0 * 100).rounded()))%" })
                sliderRow("Opacity", value: $preset.watermark.opacity, range: 0.05...1, format: { "\(Int(($0 * 100).rounded()))%" })
                row("") {
                    SettingsToggleRow(title: "Drop shadow", isOn: $preset.watermark.shadow)
                }
                WatermarkPreview(watermark: preset.watermark, sampleURL: sampleURL)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var textColorBinding: Binding<Color> {
        Binding(
            get: { Color(cgColor: ExportImageRenderer.cgColor(hex: preset.watermark.textColorHex)) },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
                preset.watermark.textColorHex = String(
                    format: "#%02X%02X%02X",
                    Int((ns.redComponent * 255).rounded()),
                    Int((ns.greenComponent * 255).rounded()),
                    Int((ns.blueComponent * 255).rounded())
                )
            }
        )
    }

    private func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .image]
        panel.prompt = "Choose"
        panel.message = "Choose a watermark or signature image (PNG with transparency)."
        if panel.runModal() == .OK, let url = panel.url {
            preset.watermark.imagePath = url.path
        }
    }

    // MARK: Other files

    private var otherFilesSection: some View {
        section("Other Files") {
            SettingsToggleRow(
                title: "Remove metadata from videos and audio",
                detail: "Re-wraps MOV, MP4, M4V and M4A without re-encoding. Other formats are copied as they are, and the summary says so.",
                isOn: $preset.stripMediaMetadata
            )
            SettingsToggleRow(
                title: "Export rendered previews of Mood, Story, .plib and .aoe files",
                detail: "Otherwise these documents are skipped. Boards render as the whole board, stories as the contact sheet, snapshots as their first image.",
                isOn: $preset.exportRenderedDocuments
            )
        }
    }

    // MARK: Layout helpers

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(title.uppercased())
                .font(.appIcon(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color.appMuted)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: AppSpacing.lg) {
            Text(label)
                .font(.appCallout)
                .foregroundStyle(Color.appPrimaryText)
                .frame(width: labelWidth, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        row(label) {
            HStack(spacing: AppSpacing.md) {
                Slider(value: value, in: range)
                    .frame(maxWidth: 200)
                    .accessibilityLabel(label)
                Text(format(value.wrappedValue))
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .frame(width: 96, alignment: .leading)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.appFootnote)
            .foregroundStyle(Color.appMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, labelWidth + AppSpacing.lg)
    }
}

/// An integer text field clamped to `range`.
private struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String

    var body: some View {
        TextField(label, value: Binding(
            get: { value },
            set: { value = min(range.upperBound, max(range.lowerBound, $0)) }
        ), format: .number.grouping(.never))
        .textFieldStyle(.roundedBorder)
        .frame(width: 72)
        .accessibilityLabel(label)
    }
}

/// 3 × 3 picker for the watermark anchor.
struct WatermarkPositionGrid: View {
    @Binding var selection: WatermarkPosition

    private let rows: [[WatermarkPosition]] = [
        [.topLeft, .top, .topRight],
        [.left, .center, .right],
        [.bottomLeft, .bottom, .bottomRight],
    ]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { r in
                HStack(spacing: 3) {
                    ForEach(rows[r]) { position in
                        Button {
                            selection = position
                        } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(position == selection ? Color.appAccent : Color.appElevatedSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(Color.appControlBorder, lineWidth: 1)
                                )
                                .frame(width: 22, height: 16)
                        }
                        .buttonStyle(.plain)
                        .help(position.title)
                        .accessibilityLabel(position.title)
                        .accessibilityAddTraits(position == selection ? .isSelected : [])
                    }
                }
            }
        }
    }
}

/// Live preview of the watermark on a sample image, rendered with the export code.
struct WatermarkPreview: View {
    let watermark: ExportWatermark
    var sampleURL: URL?

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Color.appSurface)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                    .padding(AppSpacing.sm)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 200)
        .overlay(alignment: .topLeading) {
            Text(sampleURL == nil ? "Preview (sample image)" : "Preview (\(sampleURL!.lastPathComponent))")
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)
                .padding(AppSpacing.sm)
        }
        .accessibilityLabel("Watermark preview")
        .task(id: PreviewKey(watermark: watermark, sample: sampleURL)) {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let wm = watermark
            let url = sampleURL
            let rendered = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let base: CGImage? = url.flatMap { u in
                    CGImageSourceCreateWithURL(u as CFURL, nil).flatMap { ExportImageRenderer.orientedImage(from: $0, maxPixelSize: 900) }
                } ?? WatermarkPreview.sampleImage
                guard let base else { return nil }
                let plan = ExportGeometry.plan(sourceWidth: base.width, sourceHeight: base.height, sizing: .original)
                let mark = wm.kind == .image ? ExportImageRenderer.loadWatermarkImage(path: wm.imagePath) : nil
                return ExportImageRenderer.render(
                    base, orientedSourceWidth: base.width, plan: plan,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, opaque: true,
                    watermark: wm, watermarkImage: mark
                )
            }.value
            guard !Task.isCancelled, let rendered else { return }
            image = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
        }
    }

    private struct PreviewKey: Equatable {
        var watermark: ExportWatermark
        var sample: URL?
    }

    /// A 900×600 gradient landscape standing in for a real image.
    nonisolated static let sampleImage: CGImage? = {
        let width = 900, height = 600
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let sky = CGGradient(colorsSpace: space, colors: [
                  CGColor(srgbRed: 0.98, green: 0.62, blue: 0.42, alpha: 1),
                  CGColor(srgbRed: 0.45, green: 0.30, blue: 0.62, alpha: 1),
                  CGColor(srgbRed: 0.10, green: 0.12, blue: 0.30, alpha: 1),
              ] as CFArray, locations: [0, 0.55, 1])
        else { return nil }
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [])
        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.07, blue: 0.14, alpha: 1))
        context.move(to: CGPoint(x: 0, y: 0))
        context.addLine(to: CGPoint(x: 0, y: 190))
        context.addLine(to: CGPoint(x: 260, y: 300))
        context.addLine(to: CGPoint(x: 470, y: 180))
        context.addLine(to: CGPoint(x: 680, y: 330))
        context.addLine(to: CGPoint(x: 900, y: 210))
        context.addLine(to: CGPoint(x: 900, y: 0))
        context.fillPath()
        context.setFillColor(CGColor(srgbRed: 1, green: 0.86, blue: 0.6, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: 610, y: 360, width: 90, height: 90))
        return context.makeImage()
    }()
}
