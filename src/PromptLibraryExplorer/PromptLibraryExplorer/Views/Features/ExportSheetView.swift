import AppKit
import SwiftUI

/// File ▸ Export… / Export for Sharing… and the context-menu Export items: choose or edit
/// a preset, preview what will be written, then run it with progress and cancel.
struct ExportSheetView: View {
    @Environment(ExplorerViewModel.self) private var vm
    let request: ExportRequest

    @State private var controller = ExportController.shared
    @State private var draft: ExportPreset = .sharing
    @State private var selectedPresetID: UUID?
    @State private var preview: ExportPreview?
    @State private var isPreviewing = false

    private var store: ExportPresetStore { controller.store }
    private var storedPreset: ExportPreset? { store.preset(id: selectedPresetID) }
    private var isModified: Bool { storedPreset.map { $0 != draft } ?? true }

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: draft.isSharingPreset ? "Export for Sharing" : "Export",
                subtitle: request.sourceDescription,
                systemImage: draft.isSharingPreset ? "lock.shield" : "square.and.arrow.up",
                closeTitle: controller.isRunning ? "Stop" : "Cancel",
                onClose: close
            ) {
                presetPicker
            }

            HStack(spacing: 0) {
                ScrollView {
                    ExportPresetEditorView(preset: $draft, sampleURL: sampleURL, showsName: false)
                        .padding(AppSpacing.xl)
                        .disabled(controller.isRunning)
                }
                .frame(minWidth: 460, maxWidth: .infinity)
                .background(Color.appBackground)

                Rectangle().fill(Color.appBorder).frame(width: 1)

                previewColumn
                    .frame(width: 300)
                    .background(Color.appSurface.opacity(0.5))
            }

            FeatureSheetFooter { footer }
        }
        .frame(minWidth: 800, idealWidth: 880, minHeight: 560, idealHeight: 660)
        .background(Color.appBackground)
        .onAppear {
            loadInitialPreset()
            // Every new sheet starts with edits applied (Views/Editor).
            controller.useEdits = true
        }
        .task(id: PreviewKey(preset: draft, count: request.items.count)) {
            isPreviewing = true
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let items = request.items
            let preset = draft
            let next = await Task.detached(priority: .userInitiated) {
                ExportJobPlanner.preview(items: items, preset: preset, chosenFolder: nil)
            }.value
            guard !Task.isCancelled else { return }
            preview = next
            isPreviewing = false
        }
    }

    private struct PreviewKey: Equatable {
        var preset: ExportPreset
        var count: Int
    }

    private var sampleURL: URL? {
        request.items.first(where: { FileHelpers.isImageFile($0.url.lastPathComponent) })?.url
    }

    // MARK: Preset picker

    private var presetPicker: some View {
        HStack(spacing: AppSpacing.md) {
            Picker("Preset", selection: Binding(
                get: { selectedPresetID },
                set: { id in select(id) }
            )) {
                ForEach(store.presets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(controller.isRunning)
            .accessibilityLabel("Export preset")

            if isModified {
                Text("Edited")
                    .font(.appCaptionEmphasis)
                    .foregroundStyle(Color.appAccent)
                Menu {
                    if storedPreset != nil {
                        Button("Save Changes to “\(storedPreset?.name ?? "")”") { saveToPreset() }
                        Button("Revert Changes") { revert() }
                        Divider()
                    }
                    Button("Save as New Preset…") { saveAsNew() }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(controller.isRunning)
                .help("Save these settings as a preset")
                .accessibilityLabel("Save preset")
            }
        }
    }

    private func loadInitialPreset() {
        let id = request.presetID ?? controller.lastPresetID
        let preset = store.preset(id: id) ?? store.presets.first ?? .sharing
        selectedPresetID = preset.id
        draft = preset
    }

    private func select(_ id: UUID?) {
        guard let preset = store.preset(id: id) else { return }
        selectedPresetID = preset.id
        draft = preset
    }

    private func saveToPreset() {
        guard let stored = storedPreset else { return }
        var updated = draft
        updated.id = stored.id
        updated.name = stored.name
        store.save(updated)
        draft = updated
    }

    private func revert() {
        if let stored = storedPreset { draft = stored }
    }

    private func saveAsNew() {
        let alert = NSAlert()
        alert.messageText = "Save as New Preset"
        alert.informativeText = "Name the preset. It appears in File ▸ Export With Preset and in Settings ▸ Export."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = store.uniqueName(draft.isSharingPreset ? "My Sharing Preset" : "\(draft.name) Copy")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = store.add(copyOf: draft, name: name.isEmpty ? nil : name)
        selectedPresetID = created.id
        draft = created
    }

    // MARK: Preview column

    private var previewColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                if editedCount > 0 {
                    editsChoice
                }
                if let preview {
                    previewSummary(preview)
                } else {
                    HStack(spacing: AppSpacing.md) {
                        ProgressView().controlSize(.small)
                        Text("Working out the export…")
                            .font(.appCallout)
                            .foregroundStyle(Color.appMuted)
                    }
                }
            }
            .padding(AppSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isPreviewing ? 0.7 : 1)
        }
    }

    /// Sources with a non-destructive edit (EditController).
    private var editedCount: Int {
        request.items.filter { EditController.shared.isEdited($0.url.standardizedFileURL.path) }.count
    }

    /// "Use edits / Export original" for edited images.
    private var editsChoice: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("EDITED IMAGES")
                .font(.appIcon(10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(Color.appMuted)
            Picker("Edited images", selection: Binding(
                get: { controller.useEdits },
                set: { controller.useEdits = $0 }
            )) {
                Text("Use Edits").tag(true)
                Text("Export Original").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(controller.isRunning)
            .accessibilityLabel("Edited images")
            Text(controller.useEdits
                ? "\(editedCount) edited image\(editedCount == 1 ? " is" : "s are") exported with \(editedCount == 1 ? "its" : "their") crop, rotation and adjustments."
                : "\(editedCount) edited image\(editedCount == 1 ? " is" : "s are") exported as the original file\(editedCount == 1 ? "" : "s").")
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func previewSummary(_ preview: ExportPreview) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            let count = exportableCount(preview)
            Text("\(count) file\(count == 1 ? "" : "s") to export")
                .font(.appTitle)
                .foregroundStyle(Color.appPrimaryText)
            Text("About \(ByteCountFormatter.string(fromByteCount: preview.estimatedBytes, countStyle: .file)) in total")
                .font(.appCallout)
                .foregroundStyle(Color.appMuted)
        }

        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            countRow("photo", "\(preview.imageCount) image\(preview.imageCount == 1 ? "" : "s")", show: preview.imageCount > 0)
            countRow("film", "\(preview.mediaCount) video / audio", show: preview.mediaCount > 0)
            countRow("doc.richtext", "\(preview.documentCount) document\(preview.documentCount == 1 ? "" : "s")\(draft.exportRenderedDocuments ? " (rendered)" : " (skipped)")", show: preview.documentCount > 0)
        }

        Divider().background(Color.appBorder)

        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("SAVES TO")
                .font(.appIcon(10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(Color.appMuted)
            Text(preview.destinationDescription)
                .font(.appCallout)
                .foregroundStyle(Color.appPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !preview.samples.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("FIRST NAMES")
                    .font(.appIcon(10, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(Color.appMuted)
                ForEach(preview.samples, id: \.self) { sample in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(sample.output)
                            .font(.appCalloutEmphasis)
                            .foregroundStyle(sample.action == .skip ? Color.appMuted : Color.appPrimaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(sampleCaption(sample))
                            .font(.appFootnote)
                            .foregroundStyle(sample.action == .overwrite ? Color.appError : Color.appMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(sample.output)
                }
            }
        }

        if preview.overwriteCount > 0 {
            banner("\(preview.overwriteCount) existing file\(preview.overwriteCount == 1 ? "" : "s") will be replaced (moved to the Trash). You'll be asked first.", tint: .appError)
        }
        if preview.skipCount > 0 {
            banner("\(preview.skipCount) file\(preview.skipCount == 1 ? "" : "s") will be skipped because the name is taken.", tint: .appMuted)
        }
        if !preview.destinationKnown {
            banner("Name clashes are checked once you choose the folder.", tint: .appMuted)
        }
        ForEach(preview.notes, id: \.self) { note in
            banner(note, tint: .appMuted)
        }
        banner("Originals are never changed.", tint: .appSuccess)
    }

    private func sampleCaption(_ sample: ExportPreview.Sample) -> String {
        switch sample.action {
        case .write: return "from \(sample.source)"
        case .overwrite: return "replaces an existing file · from \(sample.source)"
        case .skip: return "skipped: name taken · from \(sample.source)"
        }
    }

    @ViewBuilder
    private func countRow(_ icon: String, _ text: String, show: Bool) -> some View {
        if show {
            Label(text, systemImage: icon)
                .font(.appCallout)
                .foregroundStyle(Color.appPrimaryText)
        }
    }

    private func banner(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.appCaption)
            .foregroundStyle(Color.appPrimaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(tint.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 1))
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let progress = controller.progress {
            ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                .frame(width: 220)
                .accessibilityLabel("Export progress")
            Text("\(progress.title) \(min(progress.done + 1, progress.total)) of \(progress.total)\(progress.currentName.isEmpty ? "" : " — \(progress.currentName)")")
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Stop") { controller.cancel() }
        } else {
            Text(draft.summary)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
            Spacer()
            Button(exportButtonTitle, action: runExport)
                .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                .keyboardShortcut(.defaultAction)
                .disabled(!canExport)
        }
    }

    private func exportableCount(_ preview: ExportPreview) -> Int {
        preview.imageCount + preview.mediaCount + (draft.exportRenderedDocuments ? preview.documentCount : 0)
            - preview.skipCount
    }

    private var canExport: Bool {
        guard let preview else { return false }
        return exportableCount(preview) > 0 && !controller.isRunning
    }

    private var exportButtonTitle: String {
        draft.destination == .ask || (draft.destination == .fixedFolder && draft.fixedFolderPath == nil) ? "Export…" : "Export"
    }

    private func runExport() {
        guard canExport else { return }
        controller.lastPresetID = selectedPresetID
        controller.runExport(request, preset: draft) { summary in
            guard let summary else { return }
            let touched = Set(summary.written.compactMap { $0.destination?.deletingLastPathComponent().standardizedFileURL.path })
            if !touched.isEmpty { vm.refreshAfterExport(folders: touched) }
            controller.exportRequest = nil
            // After the sheet has gone, so the alert isn't layered on a closing sheet.
            DispatchQueue.main.async { controller.presentCompletion(summary) }
        }
    }

    private func close() {
        if controller.isRunning {
            controller.cancel()
            return
        }
        controller.exportRequest = nil
    }
}
