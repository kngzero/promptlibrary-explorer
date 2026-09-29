import SwiftUI

// MARK: - Context menu

/// Grid / list context menu: Edit Image…, Save Edited Copy…, Revert to Original.
/// Hidden for folders, videos, audio and Mood / Story / .plib / .aoe files.
struct EditorItemMenuItems: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: FileEntry
    let index: Int
    let targets: [FileEntry]

    private var edits: EditController { .shared }

    var body: some View {
        if !item.isDirectory, EditEligibility.isEditable(item.name) {
            Button("Edit Image…") {
                ContentItemActions.ensureSelected(item, at: index, vm: vm)
                vm.openEditor(for: item)
            }
            .disabled(vm.isEditorPageActive)
            if edits.isEdited(item.path) {
                Button("Save Edited Copy…") {
                    vm.saveEditedCopy(of: item)
                }
            }
            let edited = targets.filter { edits.isEdited($0.path) }
            if !edited.isEmpty {
                Button(edited.count > 1 ? "Revert \(edited.count) Images to Original" : "Revert to Original") {
                    vm.revertToOriginal(paths: edited.map(\.path))
                }
            }
        }
    }
}

/// The small "Edited" pill.
struct EditedBadge: View {
    var body: some View {
        Text("Edited")
            .font(.appMicro)
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xxs)
            .background(Capsule().fill(Color.appAccent.opacity(0.14)))
            .overlay(Capsule().strokeBorder(Color.appAccent.opacity(0.35), lineWidth: 1))
            .accessibilityLabel("Edited")
    }
}

// MARK: - Grid / list badges

/// Grid tile badge for an edited image (bottom-leading, beside the cloud badge).
struct EditedTileBadge: View {
    let item: FileEntry
    var side: CGFloat = 20

    var body: some View {
        if !item.isDirectory, EditController.shared.isEdited(item.path) {
            let shift = CloudFileController.shared.isCloudOnly(item) || CloudFileController.shared.isDownloading(item.path) ? side + 4 : 0
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.system(size: side * 0.48, weight: .semibold))
                .foregroundStyle(Color.appPrimaryText)
                .frame(width: side, height: side)
                .background(Color.appOverlaySurface, in: Circle())
                .overlay(Circle().strokeBorder(Color.appOverlayStroke, lineWidth: 1))
                .offset(x: shift)
                .help("Edited (non-destructive): shown with its crop and adjustments; the file is unchanged")
                .accessibilityLabel("Edited")
        }
    }
}

/// List-row icon for an edited image.
struct EditedInlineIcon: View {
    let path: String

    var body: some View {
        if EditController.shared.isEdited(path) {
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.appCaption)
                .foregroundStyle(Color.appAccent)
                .help("Edited (non-destructive)")
                .accessibilityLabel("Edited")
        }
    }
}

// MARK: - Lightbox

/// Lightbox header buttons: Edit (opens the editor page) and, for an edited image,
/// Show Original (per file). No key equivalents.
struct LightboxEditChromeButtons: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: FileEntry?

    private var edits: EditController { .shared }

    var body: some View {
        if let item, !item.isDirectory, EditEligibility.isEditable(item.name) {
            if edits.isEdited(item.path) {
                let showing = edits.isShowingOriginal(item.path)
                Button {
                    edits.toggleShowOriginal(item.path)
                } label: {
                    Image(systemName: showing ? "eye.slash" : "square.split.2x1")
                        .font(.appIcon(13, weight: .medium))
                }
                .buttonStyle(AppIconButtonStyle(
                    width: 30, height: 30, cornerRadius: AppRadius.md,
                    restingForeground: showing ? Color.appAccent : Color.appMuted
                ))
                .help(showing ? "Show Edited Version" : "Show Original")
                .accessibilityLabel("Show Original")
                .accessibilityValue(showing ? "On" : "Off")
            }
            Button {
                vm.openEditor(for: item)
            } label: {
                Image(systemName: "slider.horizontal.below.rectangle")
                    .font(.appIcon(13, weight: .medium))
            }
            .buttonStyle(AppIconButtonStyle(
                width: 30, height: 30, cornerRadius: AppRadius.md,
                restingForeground: edits.isEdited(item.path) ? Color.appAccent : Color.appMuted
            ))
            .help("Edit Image (crop, straighten, rotate, adjust; the file is never changed)")
            .accessibilityLabel("Edit Image")
        }
    }
}

/// "Showing original" tag over the lightbox image.
struct LightboxOriginalTag: View {
    let path: String?

    var body: some View {
        if let path, EditController.shared.isShowingOriginal(path), EditController.shared.isEdited(path) {
            Text("Original")
                .font(.appCaptionEmphasis)
                .foregroundStyle(Color.appPrimaryText)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.xs)
                .background(Capsule().fill(Color.appOverlaySurface))
                .overlay(Capsule().strokeBorder(Color.appOverlayStroke, lineWidth: 1))
                .padding(AppSpacing.xl)
                .allowsHitTesting(false)
                .accessibilityLabel("Showing the original")
        }
    }
}
