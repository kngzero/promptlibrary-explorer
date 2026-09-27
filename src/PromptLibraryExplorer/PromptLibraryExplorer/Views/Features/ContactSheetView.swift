import SwiftUI

/// File ▸ Export Contact Sheet…: lay the selection (or a collection) out as a
/// multi-page PDF.
struct ContactSheetView: View {
    let request: ContactSheetRequest

    @State private var controller = ExportController.shared
    @State private var options = ContactSheetOptions()

    private let labelWidth: CGFloat = 110

    private var layout: ContactSheetLayout {
        ContactSheetLayout(options: options, itemCount: request.items.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Export Contact Sheet",
                subtitle: request.sourceDescription,
                systemImage: "rectangle.grid.3x2",
                closeTitle: controller.isRunning ? "Stop" : "Cancel",
                onClose: close
            )

            HStack(spacing: 0) {
                ScrollView {
                    form
                        .padding(AppSpacing.xl)
                        .disabled(controller.isRunning)
                }
                .frame(width: 400)
                .background(Color.appBackground)

                Rectangle().fill(Color.appBorder).frame(width: 1)

                ContactSheetPagePreview(layout: layout, options: options, items: Array(request.items.prefix(layout.cellsPerPage)))
                    .padding(AppSpacing.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appSurface.opacity(0.5))
            }

            FeatureSheetFooter { footer }
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 560, idealHeight: 640)
        .background(Color.appBackground)
        .onAppear {
            options = controller.contactSheetOptions
            if options.title.isEmpty { options.title = request.suggestedTitle }
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            section("Page") {
                row("Paper") {
                    Picker("Paper", selection: $options.pageSize) {
                        ForEach(ContactSheetOptions.PageSize.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if options.pageSize == .custom {
                    row("Size (mm)") {
                        HStack(spacing: AppSpacing.md) {
                            decimalField($options.customWidthMM, label: "Page width in millimetres")
                            Text("×").foregroundStyle(Color.appMuted)
                            decimalField($options.customHeightMM, label: "Page height in millimetres")
                        }
                    }
                }
                row("Orientation") {
                    Picker("Orientation", selection: $options.orientation) {
                        ForEach(ContactSheetOptions.Orientation.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                row("Margins (mm)") { decimalField($options.marginMM, label: "Margins in millimetres") }
            }

            section("Grid") {
                row("Columns") { stepper($options.columns, range: 1...12, label: "Columns") }
                row("Rows") { stepper($options.rows, range: 1...16, label: "Rows") }
                row("Spacing (mm)") { decimalField($options.spacingMM, label: "Spacing in millimetres") }
            }

            section("Captions") {
                SettingsToggleRow(title: "File name", isOn: $options.captionFilename)
                SettingsToggleRow(title: "Rating and flag", isOn: $options.captionRatingFlag)
                SettingsToggleRow(title: "Prompt excerpt", isOn: $options.captionPrompt)
                if options.captionPrompt {
                    row("Prompt lines") { stepper($options.promptLines, range: 1...6, label: "Prompt lines") }
                }
            }

            section("Header & Footer") {
                SettingsToggleRow(title: "Header with title", isOn: $options.showHeader)
                if options.showHeader {
                    row("Title") {
                        TextField("Contact Sheet", text: $options.title)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Contact sheet title")
                    }
                    SettingsToggleRow(title: "Show today's date", isOn: $options.showDate)
                }
                SettingsToggleRow(title: "Page numbers", isOn: $options.showPageNumbers)
            }
        }
    }

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
        HStack(spacing: AppSpacing.lg) {
            Text(label)
                .font(.appCallout)
                .foregroundStyle(Color.appPrimaryText)
                .frame(width: labelWidth, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private func decimalField(_ value: Binding<Double>, label: String) -> some View {
        TextField(label, value: Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(2000, max(0, $0)) }
        ), format: .number.precision(.fractionLength(0...1)))
        .textFieldStyle(.roundedBorder)
        .frame(width: 64)
        .accessibilityLabel(label)
    }

    private func stepper(_ value: Binding<Int>, range: ClosedRange<Int>, label: String) -> some View {
        Stepper(value: value, in: range) {
            Text("\(value.wrappedValue)")
                .font(.appMono)
                .foregroundStyle(Color.appPrimaryText)
                .frame(minWidth: 24, alignment: .trailing)
        }
        .accessibilityLabel(label)
        .accessibilityValue("\(value.wrappedValue)")
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let progress = controller.progress {
            ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                .frame(width: 220)
                .accessibilityLabel("Contact sheet progress")
            Text("\(progress.title): \(progress.done) of \(progress.total)")
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
            Spacer()
            Button("Stop") { controller.cancel() }
        } else {
            Text("\(request.items.count) item\(request.items.count == 1 ? "" : "s") · \(layout.pageCount) page\(layout.pageCount == 1 ? "" : "s") · \(layout.columns) × \(layout.rows) per page")
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
            Spacer()
            Button("Export PDF…", action: export)
                .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                .keyboardShortcut(.defaultAction)
                .disabled(request.items.isEmpty)
        }
    }

    private func export() {
        controller.contactSheetOptions = options
        let pages = layout.pageCount
        controller.runContactSheet(request, options: options) { url in
            guard let url else { return }
            controller.contactSheetRequest = nil
            DispatchQueue.main.async { controller.presentContactSheetCompletion(url, pageCount: pages) }
        }
    }

    private func close() {
        if controller.isRunning {
            controller.cancel()
            return
        }
        controller.contactSheetOptions = options
        controller.contactSheetRequest = nil
    }
}

/// Schematic first page drawn from the same layout the PDF uses, with thumbnails.
private struct ContactSheetPagePreview: View {
    let layout: ContactSheetLayout
    let options: ContactSheetOptions
    let items: [ContactSheetItem]

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / layout.pageSize.width, proxy.size.height / layout.pageSize.height)
            let pageWidth = layout.pageSize.width * scale
            let pageHeight = layout.pageSize.height * scale
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white)
                    .shadow(color: Color.appShadowColor, radius: 6, y: 2)

                if let header = layout.headerRect {
                    Text(options.title.isEmpty ? "Contact Sheet" : options.title)
                        .font(.system(size: max(6, 15 * scale), weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .lineLimit(1)
                        .frame(width: header.width * scale, alignment: .leading)
                        .offset(x: header.minX * scale, y: header.minY * scale)
                    Rectangle()
                        .fill(Color.black.opacity(0.15))
                        .frame(width: header.width * scale, height: 0.5)
                        .offset(x: header.minX * scale, y: header.maxY * scale)
                }

                ForEach(0..<layout.cellsPerPage, id: \.self) { slot in
                    let cell = layout.cellRect(slot: slot)
                    let area = layout.imageArea(inCell: cell)
                    ZStack {
                        if slot < items.count {
                            FeatureThumbnail(path: items[slot].url.path, size: max(8, min(area.width, area.height) * scale))
                        } else {
                            RoundedRectangle(cornerRadius: 1)
                                .strokeBorder(Color.black.opacity(0.08), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                        }
                    }
                    .frame(width: area.width * scale, height: area.height * scale)
                    .offset(x: area.minX * scale, y: area.minY * scale)

                    if layout.captionHeight > 0, slot < items.count {
                        let caption = layout.captionRect(inCell: cell)
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(0..<captionLines, id: \.self) { _ in
                                Capsule().fill(Color.black.opacity(0.18)).frame(height: max(1, 2.5 * scale))
                            }
                        }
                        .frame(width: caption.width * scale * 0.8, height: caption.height * scale, alignment: .topLeading)
                        .offset(x: caption.minX * scale, y: (caption.minY + 3) * scale)
                    }
                }

                if let footer = layout.footerRect {
                    Text("Page 1 of \(max(1, layout.pageCount))")
                        .font(.system(size: max(5, 8 * scale)))
                        .foregroundStyle(Color.black.opacity(0.5))
                        .frame(width: footer.width * scale)
                        .offset(x: footer.minX * scale, y: footer.minY * scale)
                }
            }
            .frame(width: pageWidth, height: pageHeight, alignment: .topLeading)
            .clipped()
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the first page")
    }

    private var captionLines: Int {
        var lines = 0
        if options.captionFilename { lines += 1 }
        if options.captionRatingFlag { lines += 1 }
        if options.captionPrompt { lines += max(1, min(6, options.promptLines)) }
        return max(1, lines)
    }
}
