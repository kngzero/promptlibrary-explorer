import SwiftUI

/// Settings ▸ Integrations: Spotlight, Shortcuts / URL scheme, cloud placeholders.
struct IntegrationSettingsPage: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var confirmRemove = false

    private var spotlight: SpotlightController { .shared }
    private var cloud: CloudFileController { .shared }

    var body: some View {
        SettingsCard(title: "Spotlight", icon: "magnifyingglass") {
            SettingsToggleRow(
                title: "Show library files in Spotlight",
                detail: "Indexed files appear in Spotlight searches with their prompt, tags, model and rating. Choosing a result reveals the file here. Files are never changed.",
                isOn: Binding(get: { spotlight.isEnabled }, set: { spotlight.isEnabled = $0 })
            )

            if spotlight.isWorking {
                spotlightProgress
            }

            SettingsFootnote("Spotlight follows the library search index (Settings ▸ Search Index): new, moved and trashed files update it as the index does. Rebuild replaces everything; Remove takes every PromptLibrary item out of Spotlight.")

            HStack(spacing: AppSpacing.lg) {
                SettingsFilledButton(
                    title: spotlight.isWorking ? "Indexing…" : "Rebuild Spotlight Index",
                    isBusy: spotlight.isWorking,
                    isEnabled: spotlight.isEnabled && !spotlight.isWorking,
                    action: { spotlight.rebuild() }
                )
                .accessibilityHint("Rebuilds every Spotlight item from the library index")

                SettingsFilledButton(
                    title: "Remove from Spotlight",
                    tint: Color.appError,
                    isEnabled: !spotlight.isWorking,
                    action: { confirmRemove = true }
                )
                .accessibilityHint("Removes every PromptLibrary item from Spotlight")
            }

            if let error = spotlight.lastError {
                SettingsResultBanner(message: error, tone: .error)
            } else if let message = spotlight.lastMessage {
                SettingsResultBanner(message: message, tone: .success)
            }
        }
        .alert("Remove PromptLibrary files from Spotlight?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                spotlight.isEnabled = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Spotlight stops showing library files and \u{201C}Show library files in Spotlight\u{201D} is turned off. Your files and the library search index are untouched.")
        }

        SettingsCard(title: "Online-Only Cloud Files", icon: "icloud") {
            SettingsToggleRow(
                title: "Download files automatically when opened",
                detail: "Opening an online-only file (Dropbox, iCloud Drive, Google Drive) in the lightbox downloads it. Thumbnails, prompt parsing, indexing and hover scrubbing never download anything; they skip online-only files, which show a cloud badge.",
                isOn: Binding(get: { cloud.autoDownloadOnOpen }, set: { cloud.autoDownloadOnOpen = $0 })
            )
            SettingsFootnote("Right-click online-only files ▸ Download to fetch them now. Make Available Offline… downloads them and shows them in Finder, where your cloud provider's own \u{201C}Make Available Offline\u{201D} / \u{201C}Keep Downloaded\u{201D} keeps them on this Mac.")
        }

        SettingsCard(title: "Shortcuts and Links", icon: "link") {
            SettingsFootnote("Shortcuts actions: Search Library, Add Files to Collection, Export with Preset, Strip AI Metadata, Open Folder in PromptLibrary and Get Prompt of File. They appear in the Shortcuts app under PromptLibrary Explorer once the app has been installed with scripts/package_app.sh.")
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ForEach(Self.examples, id: \.self) { example in
                    HStack(spacing: AppSpacing.md) {
                        Text(example)
                            .font(.appMono)
                            .foregroundStyle(Color.appPrimaryText)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button {
                            ClipboardService.copyString(example)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.appCallout)
                        }
                        .buttonStyle(AppIconButtonStyle(width: 24, height: 24, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                        .help("Copy link")
                        .accessibilityLabel("Copy \(example)")
                    }
                }
            }
            SettingsFootnote("Any app (Shortcuts' Open URL, Terminal's open, a link in a note) can use these. Links only navigate: open a folder or file, search the library, open a collection. They never change, export or delete files.")
        }
    }

    static let examples = [
        "promptlibrary://open?path=~/Pictures/Renders",
        "promptlibrary://search?q=cinematic%20portrait",
        "promptlibrary://collection?name=Portfolio",
    ]

    @ViewBuilder
    private var spotlightProgress: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if let progress = spotlight.progress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .tint(Color.appAccent)
                Text("\(progress.done) of \(progress.total) files")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .monospacedDigit()
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.appAccent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Spotlight indexing progress")
    }
}
