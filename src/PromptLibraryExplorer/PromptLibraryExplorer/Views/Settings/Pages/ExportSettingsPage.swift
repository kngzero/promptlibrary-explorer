import SwiftUI

/// Settings ▸ Export: manage the export presets (the same editor as the export sheet).
struct ExportSettingsPage: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var store = ExportPresetStore.shared
    @State private var selectedID: UUID?
    @State private var draft: ExportPreset?

    private var stored: ExportPreset? { store.preset(id: selectedID) }
    private var isModified: Bool {
        guard let draft, let stored else { return false }
        return draft != stored
    }

    var body: some View {
        SettingsCard(title: "Presets", icon: "square.and.arrow.up.on.square") {
            SettingsFootnote("Presets appear in File ▸ Export With Preset, the Export context menus and the export sheet. Exports never change the original files.")

            VStack(spacing: 0) {
                ForEach(store.presets) { preset in
                    presetRow(preset)
                    if preset.id != store.presets.last?.id {
                        Divider().background(Color.appBorder)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(Color.appBackground))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(Color.appBorder, lineWidth: 1))

            HStack(spacing: AppSpacing.md) {
                Button("New Preset") {
                    let created = store.add(copyOf: ExportPreset(name: "New Preset"), name: "New Preset")
                    select(created.id)
                }
                Button("Duplicate") {
                    guard let stored else { return }
                    select(store.add(copyOf: stored).id)
                }
                .disabled(stored == nil)
                Button("Delete") {
                    guard let id = selectedID else { return }
                    store.delete(id: id)
                    select(store.presets.first?.id)
                }
                .disabled(stored == nil || stored?.isSharingPreset == true)
                .help(stored?.isSharingPreset == true ? "The sharing preset behind File ▸ Export for Sharing can be edited but not deleted" : "Delete this preset")
                Spacer()
                Button("Restore Default Presets") { store.restoreDefaults(); select(selectedID) }
                    .help("Resets the shipped presets; your own presets are kept")
            }
            .font(.appCallout)
        }

        if draft != nil {
            SettingsCard(title: draft?.name ?? "Preset", icon: "slider.horizontal.3") {
                ExportPresetEditorView(
                    preset: Binding(get: { draft ?? .sharing }, set: { draft = $0 }),
                    sampleURL: sampleURL
                )
                HStack(spacing: AppSpacing.md) {
                    Spacer()
                    Button("Revert") { draft = stored }
                        .disabled(!isModified)
                    Button("Save Preset") {
                        if let draft { store.save(draft) }
                    }
                    .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                    .disabled(!isModified || (draft?.name.trimmingCharacters(in: .whitespaces).isEmpty ?? true))
                }
            }
        }

        SettingsCard(title: "Sharing Privately", icon: "lock.shield") {
            SettingsFootnote("File ▸ Export for Sharing (Strip AI Metadata)… writes copies without prompts, negative prompts, seeds, generation parameters, ComfyUI graphs, A1111 parameters, EXIF/XMP descriptions and GPS. When the format and size don't change, the pixels are left exactly as they are. Every exported file is re-read afterwards and not saved if anything is left.")
            SettingsFootnote("Content Credentials (C2PA) in a PNG are left untouched; a JPEG's credentials don't survive a metadata rewrite. A changed file's credentials no longer validate either way.")
        }
        .onAppear {
            if selectedID == nil { select(store.presets.first?.id) }
        }
    }

    private var sampleURL: URL? {
        vm.selectedFileItems.first(where: { FileHelpers.isImageFile($0.name) })?.url
    }

    private func select(_ id: UUID?) {
        selectedID = id
        draft = store.preset(id: id)
    }

    private func presetRow(_ preset: ExportPreset) -> some View {
        let isSelected = preset.id == selectedID
        return Button {
            select(preset.id)
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: preset.isSharingPreset ? "lock.shield" : "square.and.arrow.up")
                    .font(.appCallout)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name)
                        .font(.appIcon(13, weight: .medium))
                        .foregroundStyle(Color.appPrimaryText)
                    Text(preset.summary)
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected, isModified {
                    Text("Edited")
                        .font(.appCaptionEmphasis)
                        .foregroundStyle(Color.appAccent)
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .background(isSelected ? Color.appSelected : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
