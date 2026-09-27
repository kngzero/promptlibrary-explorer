import AppKit
import SwiftUI

/// Edits one watched source: which new files count, and what happens to them.
/// Presented as a sheet from Settings ▸ Ingest.
struct IngestSourceEditorView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var source: IngestSource
    @State private var ignoreText: String
    @State private var tagsText: String
    @State private var minimumKB: Int
    let onSave: (IngestSource) -> Void

    private let labelWidth: CGFloat = 150

    init(source: IngestSource, onSave: @escaping (IngestSource) -> Void) {
        _source = State(initialValue: source)
        _ignoreText = State(initialValue: source.rules.ignorePatterns.joined(separator: ", "))
        _tagsText = State(initialValue: source.rules.fixedTags.joined(separator: ", "))
        _minimumKB = State(initialValue: Int(source.rules.minimumSizeBytes / 1024))
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Edit Watched Folder",
                subtitle: (source.path as NSString).abbreviatingWithTildeInPath,
                systemImage: "tray.and.arrow.down",
                closeTitle: "Cancel",
                onClose: { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    generalSection
                    filterSection
                    actionSection
                    renameSection
                    tagSection
                    previewSection
                }
                .padding(AppSpacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.appBackground)

            FeatureSheetFooter {
                Text("Rules apply to files that arrive from now on. Nothing is ever deleted.")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                Spacer(minLength: AppSpacing.lg)
                Button("Save") {
                    onSave(resolved)
                    dismiss()
                }
                .buttonStyle(AppPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .frame(width: 620, height: 640)
        .background(Color.appBackground)
    }

    // MARK: Sections

    private var generalSection: some View {
        section("Folder") {
            row("Name") {
                TextField("Name", text: $source.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Source name")
            }
            row("") {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    SettingsToggleRow(title: "Watch this folder", isOn: $source.isEnabled)
                    SettingsToggleRow(title: "Include subfolders", isOn: $source.includeSubfolders)
                    SettingsToggleRow(
                        title: "Process files added while the app was closed",
                        detail: "On launch, files that arrived since the app last ran go through these rules too.",
                        isOn: $source.processWhileClosed
                    )
                }
            }
        }
    }

    private var filterSection: some View {
        section("Which Files") {
            row("Types") {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    ForEach(IngestFileKinds.choices, id: \.kind.rawValue) { choice in
                        SettingsToggleRow(title: choice.title, isOn: kindBinding(choice.kind))
                    }
                }
            }
            row("Minimum size") {
                HStack(spacing: AppSpacing.sm) {
                    TextField("0", value: $minimumKB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .accessibilityLabel("Minimum size in kilobytes")
                    Text("KB (0 = any size)")
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                }
            }
            row("Ignore") {
                TextField("*_temp_*, preview/*", text: $ignoreText)
                    .textFieldStyle(.roundedBorder)
                    .font(.appMono)
                    .accessibilityLabel("Ignore patterns")
            }
            hint("Comma-separated patterns (* and ?) matched against the file name or its path inside the folder. Hidden and partially downloaded files are always ignored.")
        }
    }

    private var actionSection: some View {
        section("What Happens") {
            row("") {
                SettingsChoiceRow(
                    options: IngestAction.allCases,
                    title: { $0.title },
                    explanation: { $0.explanation },
                    selection: $source.rules.action
                )
            }
            if source.rules.action != .leaveInPlace {
                row("Destination") {
                    HStack(spacing: AppSpacing.md) {
                        Text(destinationLabel)
                            .font(.appCallout)
                            .foregroundStyle(Color.appPrimaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(destinationLabel)
                        Button("Choose…") { chooseDestination() }
                            .buttonStyle(AppLabeledButtonStyle(height: 24))
                            .accessibilityHint("Chooses the library folder new files go into")
                        if source.rules.destinationPath != nil {
                            Button("Use Library Root") { source.rules.destinationPath = nil }
                                .buttonStyle(AppLabeledButtonStyle(height: 24))
                        }
                    }
                }
                row("") {
                    SettingsToggleRow(title: "Sort into dated subfolders", isOn: $source.rules.usesDatedSubfolders)
                }
                if source.rules.usesDatedSubfolders {
                    row("Subfolder pattern") {
                        TextField(IngestRules.defaultDatedTemplate, text: $source.rules.datedSubfolderTemplate)
                            .textFieldStyle(.roundedBorder)
                            .font(.appMono)
                            .frame(maxWidth: 200)
                            .accessibilityLabel("Dated subfolder pattern")
                    }
                    hint("Date format per folder level, with / between levels: yyyy/MM-dd makes 2026/09-27. Uses the date the file arrived.")
                }
                hint("A file that is byte-for-byte identical to one already in the destination isn't copied or moved: the Inbox links the existing file, and the new one stays where it is.")
            }
        }
    }

    private var renameSection: some View {
        section("Rename") {
            row("File name") {
                HStack(spacing: AppSpacing.md) {
                    TextField("Keep the original name", text: $source.rules.renameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.appMono)
                        .accessibilityLabel("Rename template")
                    Menu {
                        ForEach(RenameTemplateService.tokens, id: \.token) { token in
                            Button("\(token.token) — \(token.description)") {
                                source.rules.renameTemplate += token.token
                            }
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
            hint("Batch Rename tokens ({date}, {model}, {seed}, {prompt:30}…). Names are never overwritten: a taken name gets a number. With Leave in Place the file is renamed where it is (undoable).")
        }
    }

    private var tagSection: some View {
        section("Tag & Collect") {
            row("Tags") {
                TextField("ComfyUI, to review", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Tags to add")
            }
            row("") {
                SettingsToggleRow(
                    title: "Tag with the model name",
                    detail: "Reads the checkpoint / model from the file's embedded generation data.",
                    isOn: $source.rules.tagWithModelName
                )
            }
            row("Add to collection") {
                Picker("Add to collection", selection: $source.rules.collectionID) {
                    Text("None").tag(UUID?.none)
                    ForEach(vm.collections) { collection in
                        Text(collection.name).tag(UUID?.some(collection.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var previewSection: some View {
        section("Example") {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)
                Text(examplePath)
                    .font(.appMono)
                    .foregroundStyle(Color.appPrimaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Example result: \(examplePath)")
        }
    }

    // MARK: Helpers

    private var resolved: IngestSource {
        var result = source
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.name.isEmpty { result.name = URL(fileURLWithPath: result.path).lastPathComponent }
        result.rules.ignorePatterns = IngestRuleEngine.list(from: ignoreText)
        result.rules.fixedTags = IngestRuleEngine.list(from: tagsText)
        result.rules.minimumSizeBytes = Int64(max(0, minimumKB)) * 1024
        if result.rules.kinds.isEmpty { result.rules.kinds = .all }
        return result
    }

    private var isValid: Bool {
        !source.rules.kinds.isEmpty
    }

    private var destinationLabel: String {
        if let path = source.rules.destinationPath { return (path as NSString).abbreviatingWithTildeInPath }
        if let root = vm.explorerRootPath { return "Library root (\((root.path as NSString).abbreviatingWithTildeInPath))" }
        return "Library root (open a library first)"
    }

    private var examplePath: String {
        let rules = resolved.rules
        let sample = URL(fileURLWithPath: source.path).appendingPathComponent("ComfyUI_00042_.png")
        let context = RenameTemplateContext(
            url: sample, index: 0, modifiedDate: Date(), prompt: "a lighthouse at dusk, volumetric fog",
            model: "sd_xl_base_1.0.safetensors", seed: "123456789", sampler: "euler", steps: "30", cfg: "7",
            width: 1024, height: 1024
        )
        let name = IngestRuleEngine.renamedFileName(template: rules.renameTemplate, context: context) ?? sample.lastPathComponent
        var text: String
        switch rules.action {
        case .leaveInPlace:
            text = (sample.deletingLastPathComponent().appendingPathComponent(name).path as NSString).abbreviatingWithTildeInPath
        case .copy, .move:
            if let folder = IngestRuleEngine.destinationFolder(rules: rules, libraryRoot: vm.explorerRootPath, date: Date()) {
                text = (folder.appendingPathComponent(name).path as NSString).abbreviatingWithTildeInPath
            } else {
                text = "Choose a destination (no library is open)"
            }
        }
        let tags = IngestRuleEngine.tagNames(rules: rules, model: "sd_xl_base_1.0.safetensors")
        if !tags.isEmpty { text += "\ntags: " + tags.joined(separator: ", ") }
        return text
    }

    private func kindBinding(_ kind: IngestFileKinds) -> Binding<Bool> {
        Binding(
            get: { source.rules.kinds.contains(kind) },
            set: { on in
                if on { source.rules.kinds.insert(kind) } else { source.rules.kinds.remove(kind) }
            }
        )
    }

    private func chooseDestination() {
        let start = source.rules.destinationPath.map { URL(fileURLWithPath: $0) } ?? vm.explorerRootPath
        guard let url = FileSystemService.openFolderDialog(title: "Choose Destination Folder", prompt: "Choose", directoryURL: start)
        else { return }
        source.rules.destinationPath = url.standardizedFileURL.path
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
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.lg) {
            Text(label)
                .font(.appCallout)
                .foregroundStyle(Color.appPrimaryText)
                .frame(width: labelWidth, alignment: .trailing)
                .accessibilityHidden(label.isEmpty)
            content()
            Spacer(minLength: 0)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.appCaption)
            .foregroundStyle(Color.appMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, labelWidth + AppSpacing.lg)
    }
}
