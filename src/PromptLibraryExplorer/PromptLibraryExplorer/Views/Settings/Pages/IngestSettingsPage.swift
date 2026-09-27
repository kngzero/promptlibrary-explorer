import SwiftUI

/// Settings ▸ Ingest: live folder updates, the watched source folders and their
/// rules, and recent ingest activity.
struct IngestSettingsPage: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Bindable private var liveUpdates = FolderWatcherController.shared
    private var controller: IngestController { .shared }

    @State private var editing: IngestSource?
    @State private var pendingRemoval: IngestSource?
    @State private var showsLog = false

    var body: some View {
        SettingsCard(title: "Live Folder Updates", icon: "arrow.triangle.2.circlepath") {
            SettingsToggleRow(
                title: "Update the browser when files change on disk",
                detail: "New, changed and removed files appear in the open folder within a second or two, without reloading it, and go straight into the search and visual indexes. Files still being written (large PNGs, videos) are picked up once they stop growing.",
                isOn: $liveUpdates.isEnabled
            )
            SettingsStatRow(
                label: "Watching",
                detail: liveUpdates.isWatching ? "the open library and its subfolders" : (liveUpdates.isEnabled ? "open a folder to start" : "off"),
                value: liveUpdates.isWatching ? (liveUpdates.root?.lastPathComponent ?? "—") : "—"
            )
        }

        SettingsCard {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                Label("Watched Folders", systemImage: "tray.and.arrow.down")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appAccent)
                Spacer(minLength: 0)
                Button {
                    addSource()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                        .font(.appCallout)
                }
                .buttonStyle(AppLabeledButtonStyle(height: 26))
                .help("Watch a folder (ComfyUI output, Downloads…) for new files")
                .accessibilityHint("Chooses a folder to watch for new files")
            }

            if controller.sources.isEmpty {
                SettingsFootnote("Add a folder your generators or browser save into. New files that appear in it show up in the sidebar's Inbox, and can be copied or moved into your library, renamed, tagged and collected on the way. Files already in the folder are left alone unless you choose Process Existing Files.")
            } else {
                VStack(spacing: AppSpacing.md) {
                    ForEach(controller.sources) { source in
                        IngestSourceRow(
                            source: source,
                            isAvailable: controller.isAvailable(source),
                            onToggle: { enabled in
                                var next = source
                                next.isEnabled = enabled
                                controller.updateSource(next)
                            },
                            onEdit: { editing = source },
                            onProcessExisting: { controller.processExistingNow(sourceID: source.id) },
                            onShowInbox: { vm.openInbox(sourceID: source.id) },
                            onRemove: { pendingRemoval = source }
                        )
                    }
                }
            }

            SettingsFootnote("Ingest never deletes anything. A file identical to one already in the destination isn't copied or moved; the Inbox links the existing file and the new one stays where it is. Moves and renames can be undone with Edit ▸ Undo.")
        }
        .sheet(item: $editing) { source in
            IngestSourceEditorView(source: source) { updated in
                controller.updateSource(updated)
            }
            .environment(vm)
        }
        .alert(
            "Stop watching \u{201C}\(pendingRemoval?.name ?? "")\u{201D}?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button("Stop Watching") {
                if let id = pendingRemoval?.id { controller.removeSource(id: id) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("The folder and its files are not changed, and files already in the Inbox stay there.")
        }

        SettingsCard {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                Label("Recent Activity", systemImage: "list.bullet.rectangle")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appAccent)
                Spacer(minLength: 0)
                if controller.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Processing new files")
                }
                Button("Show Full Log…") { showsLog = true }
                    .buttonStyle(AppLabeledButtonStyle(height: 26))
                    .font(.appCallout)
                    .disabled(controller.log.isEmpty)
            }
            IngestLogList(limit: 8)
        }
        .sheet(isPresented: $showsLog) {
            IngestLogSheet()
        }
    }

    private func addSource() {
        guard let url = FileSystemService.openFolderDialog(
            title: "Choose a Folder to Watch",
            prompt: "Watch",
            directoryURL: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ) else { return }
        if let source = controller.addSource(url) {
            editing = source
        }
    }
}

private struct IngestSourceRow: View {
    let source: IngestSource
    let isAvailable: Bool
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onProcessExisting: () -> Void
    let onShowInbox: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
            Button {
                onToggle(!source.isEnabled)
            } label: {
                Image(systemName: source.isEnabled ? "checkmark.square.fill" : "square")
                    .font(.appBody)
                    .foregroundStyle(source.isEnabled ? Color.appAccent : Color.appMuted)
            }
            .buttonStyle(.plain)
            .help(source.isEnabled ? "Pause watching this folder" : "Watch this folder")
            .accessibilityLabel(source.isEnabled ? "Pause watching \(source.name)" : "Watch \(source.name)")

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                HStack(spacing: AppSpacing.sm) {
                    Text(source.name)
                        .font(.appIcon(13, weight: .semibold))
                        .foregroundStyle(Color.appPrimaryText)
                    if !isAvailable {
                        Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                            .font(.appCaption)
                            .foregroundStyle(Color.appError)
                            .help("The folder can't be reached (disconnected volume, moved or deleted). It's picked up again when it comes back.")
                    }
                }
                Text((source.path as NSString).abbreviatingWithTildeInPath)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(source.path)
                Text(summary)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: AppSpacing.xs) {
                iconButton("pencil", help: "Edit rules", action: onEdit)
                iconButton("tray.full", help: "Show this folder's Inbox", action: onShowInbox)
                iconButton("arrow.down.doc", help: "Process existing files now (applies the rules to files already in the folder)", action: onProcessExisting)
                    .disabled(!isAvailable || !source.isEnabled)
                iconButton("minus.circle", help: "Stop watching (no files are changed)", action: onRemove)
            }
        }
        .padding(AppSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.appBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private var summary: String {
        let rules = source.rules
        var parts: [String] = [rules.action.title]
        if rules.action != .leaveInPlace {
            let destination = rules.destinationPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "library root"
            parts[0] += " \u{201C}\(destination)\u{201D}"
            if rules.usesDatedSubfolders { parts.append("dated (\(rules.datedSubfolderTemplate))") }
        }
        if !rules.renameTemplate.isEmpty { parts.append("rename \(rules.renameTemplate)") }
        let tags = rules.fixedTags + (rules.tagWithModelName ? ["model name"] : [])
        if !tags.isEmpty { parts.append("tags: " + tags.joined(separator: ", ")) }
        if rules.kinds != .all {
            let kinds = IngestFileKinds.choices.filter { rules.kinds.contains($0.kind) }.map(\.title)
            parts.append(kinds.joined(separator: ", ").lowercased() + " only")
        }
        return parts.joined(separator: " · ")
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.appCalloutEmphasis)
        }
        .buttonStyle(AppIconButtonStyle(width: 26, height: 26, cornerRadius: AppRadius.sm, showsRestingChrome: false))
        .help(help)
        .accessibilityLabel(help)
    }
}
