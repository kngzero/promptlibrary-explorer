import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Data: backups, export / import, the library data file, Finder tags and
/// XMP sidecars.
struct DataSettingsPage: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Bindable private var curation = CurationController.shared

    @State private var resultMessage: (text: String, tone: ToastType)?
    @State private var importRequest: CurationImportRequest?
    @State private var showingBackups = false
    @State private var isBackingUp = false
    @State private var isUndoing = false
    @State private var isSyncing = false
    @State private var confirmUndo = false

    var body: some View {
        Group {
            backupsCard
            exportImportCard
            if let resultMessage {
                SettingsResultBanner(message: resultMessage.text, tone: resultMessage.tone)
            }
            librarySyncCard
            finderTagsCard
            sidecarsCard
        }
        .sheet(item: $importRequest) { request in
            CurationImportSheet(request: request) { outcome in
                importRequest = nil
                if let outcome { resultMessage = outcome }
            }
        }
        .sheet(isPresented: $showingBackups) {
            CurationBackupListSheet { info in
                showingBackups = false
                if let info { Task { await openBackup(info) } }
            }
        }
        .alert("Undo the last import?", isPresented: $confirmUndo) {
            Button("Undo Import", role: .destructive) { Task { await undoImport() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your curation goes back to exactly what it was before the import. A backup of the current state is taken first.")
        }
    }

    // MARK: Backups

    private var backupsCard: some View {
        SettingsCard(title: "Backups", icon: "clock.arrow.circlepath") {
            VStack(spacing: AppSpacing.md) {
                SettingsStatRow(
                    label: "Last backup",
                    detail: "daily, and before every import, restore or upgrade",
                    value: curation.lastBackupAt.map(relative) ?? "Never"
                )
                SettingsStatRow(
                    label: "Kept",
                    detail: "Application Support ▸ PromptLibraryExplorer ▸ Backups",
                    value: "14 daily + 8 weekly"
                )
            }

            if let error = curation.lastBackupError {
                SettingsResultBanner(message: "The last backup failed: \(error)", tone: .error)
            }

            extraFolderRow

            HStack(spacing: AppSpacing.lg) {
                SettingsFilledButton(title: "Back Up Now", isBusy: isBackingUp) {
                    isBackingUp = true
                    defer { isBackingUp = false }
                    if curation.takeBackupNow(reason: .manual) != nil {
                        resultMessage = ("Backed up your curation.", .success)
                    }
                }
                Button("Restore from Backup…") { showingBackups = true }
                    .buttonStyle(AppLabeledButtonStyle(height: 32, horizontalPadding: AppSpacing.lg))
                Button("Reveal Backups Folder") { curation.revealBackupsFolder() }
                    .buttonStyle(AppLabeledButtonStyle(height: 32, horizontalPadding: AppSpacing.lg))
            }
        }
    }

    private var extraFolderRow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
                Text("Extra backup folder")
                    .font(.appIcon(14, weight: .medium))
                    .foregroundStyle(Color.appPrimaryText)
                Text(curation.extraBackupFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "None")
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: AppSpacing.md)
                Button("Choose…", action: chooseExtraFolder)
                    .buttonStyle(AppLabeledButtonStyle())
                if curation.extraBackupFolder != nil {
                    Button("Remove") { curation.extraBackupFolder = nil }
                        .buttonStyle(AppLabeledButtonStyle())
                }
            }
            SettingsFootnote("Every backup is also copied here — pick a folder in Dropbox to keep a copy off this Mac.")
        }
    }

    // MARK: Export / import

    private var exportImportCard: some View {
        SettingsCard(title: "Export & Import", icon: "square.and.arrow.up.on.square") {
            SettingsFootnote("Exports ratings, flags, tags, favorites, custom orders, smart folders, collections and sets, snippets, recent folders and settings to one JSON file. Import shows what will change first, and can be undone.")

            HStack(spacing: AppSpacing.lg) {
                SettingsFilledButton(title: "Export Curation Data…") { exportData() }
                Button("Import…", action: chooseImportFile)
                    .buttonStyle(AppLabeledButtonStyle(height: 32, horizontalPadding: AppSpacing.lg))
            }

            if let undo = curation.lastImportUndo {
                HStack(spacing: AppSpacing.md) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(Color.appAccent)
                        .accessibilityHidden(true)
                    Text("Imported \(undo.sourceName) \(relative(undo.importedAt)).")
                        .font(.appCallout)
                        .foregroundStyle(Color.appPrimaryText)
                    Spacer(minLength: AppSpacing.md)
                    Button(isUndoing ? "Undoing…" : "Undo Import") { confirmUndo = true }
                        .buttonStyle(AppLabeledButtonStyle())
                        .disabled(isUndoing)
                }
            }
        }
    }

    // MARK: Library sync

    private var librarySyncCard: some View {
        SettingsCard(title: "Sync Between Macs", icon: "arrow.triangle.2.circlepath") {
            SettingsToggleRow(
                title: "Keep a library data file in each library",
                detail: "Stores the curation of the files in a library in a hidden .promptlibrary/curation.json inside it, with paths relative to the library, so Dropbox (or any folder sync) carries it to your other Macs. Changes are merged file by file; the newest wins, and nothing is overwritten on conflict.",
                isOn: $curation.librarySyncEnabled
            )

            if curation.librarySyncEnabled {
                let status = curation.syncStatus
                VStack(spacing: AppSpacing.md) {
                    SettingsStatRow(
                        label: "Library",
                        detail: status.libraryRoot.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "open a folder to sync it",
                        value: status.libraryRoot?.lastPathComponent ?? "—"
                    )
                    SettingsStatRow(label: "Status", detail: status.lastError ?? statusDetail(status), value: statusValue(status))
                    SettingsStatRow(
                        label: "Merged from other Macs",
                        detail: "values brought in this session",
                        value: "\(status.remoteChangesApplied)"
                    )
                    SettingsStatRow(
                        label: "Conflicts merged",
                        detail: status.conflictedCopiesMerged > 0
                            ? "plus \(status.conflictedCopiesMerged) Dropbox conflicted \(status.conflictedCopiesMerged == 1 ? "copy" : "copies")"
                            : "simultaneous edits; this Mac's value kept",
                        value: "\(status.conflictsMerged)"
                    )
                }

                HStack(spacing: AppSpacing.lg) {
                    SettingsFilledButton(
                        title: "Sync Now",
                        isBusy: isSyncing || status.isSyncing,
                        isEnabled: status.libraryRoot != nil
                    ) {
                        isSyncing = true
                        await curation.syncLibraryNow()
                        isSyncing = false
                    }
                    if let root = status.libraryRoot, status.fileExists {
                        Button("Reveal Library File") {
                            NSWorkspace.shared.activateFileViewerSelecting([LibrarySyncIO.fileURL(for: root)])
                        }
                        .buttonStyle(AppLabeledButtonStyle(height: 32, horizontalPadding: AppSpacing.lg))
                    }
                }
            }
        }
    }

    private func statusValue(_ status: LibrarySyncStatus) -> String {
        if status.lastError != nil { return "Paused" }
        if status.isSyncing { return "Syncing…" }
        guard let synced = status.lastSyncedAt else { return status.libraryRoot == nil ? "—" : "Waiting" }
        return "Synced \(relative(synced))"
    }

    private func statusDetail(_ status: LibrarySyncStatus) -> String {
        if status.libraryRoot == nil { return "no library open" }
        if !status.fileExists { return "no data file yet (created when there's curation to sync)" }
        if let write = status.lastWriteAt { return "file last written \(relative(write))" }
        return "up to date with the library file"
    }

    // MARK: Finder tags

    private var finderTagsCard: some View {
        SettingsCard(title: "Finder Tags", icon: "tag") {
            SettingsToggleRow(
                title: "Mirror tags to Finder",
                detail: "The app's tags become Finder tags on the files, and Finder tags you add elsewhere show up in the app (Finder's colour tags stay labels). Removing a tag on either side removes it on the other. File contents and modification dates are never changed.",
                isOn: $curation.finderTagSyncEnabled
            )
            if curation.finderTagSyncEnabled, curation.finderTagFilesSynced > 0 {
                SettingsStatRow(label: "Files synced", detail: "this session", value: "\(curation.finderTagFilesSynced)")
            }
        }
    }

    // MARK: XMP

    private var sidecarsCard: some View {
        SettingsCard(title: "XMP Sidecars", icon: "doc.badge.gearshape") {
            SettingsToggleRow(
                title: "Write and read XMP sidecars",
                detail: "Keeps a Lightroom / Bridge style <name>.xmp next to each image, video or audio file with its rating, label, tags, flag and prompts, and imports ratings, labels and keywords from existing sidecars when the app has none. Originals are never modified; sidecars move, rename and go to the Trash with their files.",
                isOn: $curation.xmpSidecarsEnabled
            )
            HStack(spacing: AppSpacing.lg) {
                let count = vm.xmpSidecarTargets.count
                SettingsFilledButton(
                    title: "Write XMP Sidecars Now",
                    isBusy: curation.isWritingSidecars,
                    isEnabled: count > 0
                ) {
                    vm.writeXMPSidecarsNow()
                }
                Text(count == 0 ? "Select files or open a folder first." : (vm.selectedItems.isEmpty ? "All \(count) files in this folder" : "\(count) selected \(count == 1 ? "file" : "files")"))
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
            }
        }
    }

    // MARK: Actions

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        if abs(date.timeIntervalSinceNow) < 45 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder for extra copies of your curation backups"
        if panel.runModal() == .OK, let url = panel.url {
            curation.extraBackupFolder = url
            if curation.takeBackupNow(reason: .manual) != nil {
                resultMessage = ("Backups will also be copied to \(url.lastPathComponent).", .success)
            }
        }
    }

    private func exportData() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "PromptLibrary Curation \(formatter.string(from: Date())).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let counts = try curation.export(to: url)
            resultMessage = ("Exported \(counts.summary.lowercased()) to \(url.lastPathComponent).", .success)
        } catch {
            resultMessage = ("Export failed: \(error.localizedDescription)", .error)
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "Preview Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let bundle = try await curation.loadBundle(from: url)
                importRequest = CurationImportRequest(bundle: bundle, sourceName: url.lastPathComponent, isRestore: false)
            } catch {
                resultMessage = (error.localizedDescription, .error)
            }
        }
    }

    private func openBackup(_ info: CurationBackupInfo) async {
        do {
            let bundle = try await curation.loadBundle(from: info.url)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            importRequest = CurationImportRequest(
                bundle: bundle,
                sourceName: "the backup from \(formatter.string(from: info.createdAt))",
                isRestore: true
            )
        } catch {
            resultMessage = (error.localizedDescription, .error)
        }
    }

    private func undoImport() async {
        isUndoing = true
        defer { isUndoing = false }
        do {
            try await curation.undoLastImport()
            resultMessage = ("Import undone. Everything is as it was before.", .success)
        } catch {
            resultMessage = (error.localizedDescription, .error)
        }
    }
}

// MARK: - Import preview

struct CurationImportRequest: Identifiable {
    let id = UUID()
    let bundle: CurationBundle
    let sourceName: String
    let isRestore: Bool
}

private struct CurationImportSheet: View {
    let request: CurationImportRequest
    let onFinish: ((text: String, tone: ToastType)?) -> Void

    @State private var mode: CurationImportMode = .merge
    @State private var includeSettings = false
    @State private var errorMessage: String?

    private var curation: CurationController { .shared }

    private var changes: [CurationImportKindChange] {
        curation.previewImport(request.bundle, mode: mode, includeSettings: includeSettings)
    }

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: request.isRestore ? "Restore from Backup" : "Import Curation Data",
                subtitle: headerSubtitle,
                systemImage: request.isRestore ? "clock.arrow.circlepath" : "square.and.arrow.down",
                closeTitle: "Cancel",
                onClose: { onFinish(nil) }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    SettingsChoiceRow(
                        options: CurationImportMode.allCases,
                        title: \.title,
                        explanation: \.explanation,
                        selection: $mode
                    )

                    SettingsToggleRow(
                        title: "Also restore app settings",
                        detail: "Appearance, filters, sort, view and sync preferences. Some take effect after a relaunch.",
                        isOn: $includeSettings
                    )

                    changesTable

                    SettingsFootnote("A backup of your current curation is taken first; Settings ▸ Data ▸ Undo Import puts it back.")

                    if let errorMessage {
                        SettingsResultBanner(message: errorMessage, tone: .error)
                    }
                }
                .padding(AppSpacing.xl)
            }

            FeatureSheetFooter {
                Spacer()
                Button("Cancel") { onFinish(nil) }
                    .buttonStyle(AppLabeledButtonStyle())
                Button(request.isRestore ? "Restore" : "Import") { runImport() }
                    .buttonStyle(AppPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!changes.contains(where: \.hasChanges))
            }
        }
        .frame(width: 560, height: 600)
        .background(Color.appBackground)
        .onAppear { mode = request.isRestore ? .replace : .merge }
    }

    private var headerSubtitle: String {
        let bundle = request.bundle
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var parts = [formatter.string(from: bundle.createdAt)]
        if !bundle.machineName.isEmpty { parts.append(bundle.machineName) }
        if !bundle.appVersion.isEmpty { parts.append("app \(bundle.appVersion)") }
        return parts.joined(separator: " · ")
    }

    private var changesTable: some View {
        VStack(spacing: 0) {
            row(title: "", incoming: "In file", added: "New", changed: "Changed", removed: "Removed", isHeader: true)
            Divider().background(Color.appBorder)
            ForEach(changes) { change in
                row(
                    title: change.title,
                    incoming: "\(change.incoming)",
                    added: change.added > 0 ? "+\(change.added)" : "–",
                    changed: change.changed > 0 ? "\(change.changed)" : "–",
                    removed: change.removed > 0 ? "−\(change.removed)" : "–",
                    isHeader: false
                )
            }
        }
        .padding(AppSpacing.md)
        .background(RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.appSurface))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).strokeBorder(Color.appBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What the import changes")
    }

    private func row(title: String, incoming: String, added: String, changed: String, removed: String, isHeader: Bool) -> some View {
        HStack(spacing: AppSpacing.md) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(incoming).frame(width: 64, alignment: .trailing)
            Text(added).frame(width: 64, alignment: .trailing)
                .foregroundStyle(isHeader ? Color.appMuted : Color.appSuccess)
            Text(changed).frame(width: 64, alignment: .trailing)
            Text(removed).frame(width: 64, alignment: .trailing)
                .foregroundStyle(isHeader || removed == "–" ? Color.appMuted : Color.appError)
        }
        .font(isHeader ? .appCaptionEmphasis : .appCallout.monospacedDigit())
        .foregroundStyle(isHeader ? Color.appMuted : Color.appPrimaryText)
        .padding(.vertical, AppSpacing.xs)
    }

    private func runImport() {
        do {
            try curation.importBundle(
                request.bundle,
                mode: mode,
                includeSettings: includeSettings,
                sourceName: request.sourceName,
                reason: request.isRestore ? .preRestore : .preImport
            )
            let verb = request.isRestore ? "Restored" : "Imported"
            onFinish(("\(verb) \(request.sourceName). Undo Import puts back what you had.", .success))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Backup list

private struct CurationBackupListSheet: View {
    let onFinish: (CurationBackupInfo?) -> Void

    @State private var backups: [CurationBackupInfo]?
    @State private var selection: CurationBackupInfo.ID?

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Restore from Backup",
                subtitle: "Choose a backup to preview what restoring it would change",
                systemImage: "clock.arrow.circlepath",
                closeTitle: "Cancel",
                onClose: { onFinish(nil) }
            )

            Group {
                if let backups {
                    if backups.isEmpty {
                        FeatureEmptyState(systemImage: "clock.badge.questionmark", title: "No backups yet", message: "A backup is taken every day and before every import.")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: AppSpacing.xxs) {
                                ForEach(backups) { backup in
                                    backupRow(backup)
                                }
                            }
                            .padding(AppSpacing.md)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            FeatureSheetFooter {
                Spacer()
                Button("Cancel") { onFinish(nil) }
                    .buttonStyle(AppLabeledButtonStyle())
                Button("Preview Restore…") {
                    onFinish(backups?.first { $0.id == selection })
                }
                .buttonStyle(AppPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .frame(width: 560, height: 520)
        .background(Color.appBackground)
        .task { backups = await CurationController.shared.listBackups() }
    }

    private func backupRow(_ backup: CurationBackupInfo) -> some View {
        let isSelected = backup.id == selection
        return Button {
            selection = backup.id
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.lg) {
                Image(systemName: backup.reason == .daily ? "calendar" : "shield.lefthalf.filled")
                    .font(.appIcon(14))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    HStack(spacing: AppSpacing.sm) {
                        Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.appHeadline)
                            .foregroundStyle(Color.appPrimaryText)
                        Text(backup.reason.title)
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                        if backup.isInExtraFolder {
                            Text("Extra folder")
                                .font(.appCaption)
                                .foregroundStyle(Color.appMuted)
                        }
                    }
                    Text("\(backup.machineName) · \(backup.counts.summary)")
                        .font(.appCallout)
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(AppSpacing.md)
            .background(FeatureRowBackground(isSelected: isSelected, isHovered: false))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(backup.reason.title) backup, \(backup.createdAt.formatted()), \(backup.counts.summary)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
