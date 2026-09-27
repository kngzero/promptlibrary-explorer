import SwiftUI

/// Edit ▸ Edit Image… (context menu, details panel, the lightbox's Edit button): a full
/// page over the content browser and the details panel, like Compare and Similar
/// Images — the sidebar stays and the browser keeps running underneath.
///
/// Non-destructive: Done saves a recipe (one undoable step in the app's history);
/// the file on disk is never changed. Esc / Cancel discards the session's changes
/// (asking first when there are any). ⌘Z / ⇧⌘Z undo inside the session.
struct EditorPageView: View {
    @Environment(ExplorerViewModel.self) private var vm
    let session: EditorSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.appBorder)
            EditorToolbar(session: session)
                .padding(.horizontal, AppSpacing.xl)
                .padding(.vertical, AppSpacing.sm)
                .background(Color.appSurface)
            Divider().background(Color.appBorder)
            HStack(spacing: 0) {
                EditorCanvasView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Color.appBorder).frame(width: 1)
                EditorInspectorView(session: session)
                    .frame(width: 280)
                    .background(Color.appSurface.opacity(0.6))
            }
        }
        .background(Color.appBackground)
        .task(id: session.id) {
            if session.baseImage == nil { await session.load() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit Image")
    }

    private var header: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.appIcon(15, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Edit Image")
                    .font(.appTitle)
                    .foregroundStyle(Color.appPrimaryText)
                Text(subtitle)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: AppSpacing.lg)
            // Esc is owned by the key monitor (no key equivalents here).
            Button("Cancel") {
                vm.requestCancelEditor()
            }
            .buttonStyle(AppLabeledButtonStyle(height: 28, horizontalPadding: AppSpacing.lg))
            .help("Close without saving (Esc)")
            Button {
                vm.closeEditor(save: true)
            } label: {
                Text("Done")
                    .font(.appCalloutEmphasis)
            }
            .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
            .disabled(session.isLoading || session.loadError != nil)
            .help(session.isDirty ? "Save the edit (the file itself is never changed)" : "Back to the browser")
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.md)
        .background(Color.appSurface)
    }

    private var subtitle: String {
        var parts = [session.name]
        let size = session.outputSize
        if size.width > 0 { parts.append("\(Int(size.width)) × \(Int(size.height)) px") }
        parts.append(session.isDirty ? "Unsaved changes" : "Non-destructive: the original file is never changed")
        return parts.joined(separator: " · ")
    }
}

/// Tool picker, undo / redo, hold-to-compare and Revert to Original.
struct EditorToolbar: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Picker("Tool", selection: $session.tool) {
                ForEach(EditorTool.allCases) { tool in
                    Label(tool.title, systemImage: tool.systemImage).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Editing tool")

            Divider().frame(height: 18)

            Button { session.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.appIcon(13, weight: .medium))
            }
            .buttonStyle(AppIconButtonStyle())
            .disabled(!session.canUndo)
            .help("Undo (⌘Z)")
            .accessibilityLabel("Undo")

            Button { session.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.appIcon(13, weight: .medium))
            }
            .buttonStyle(AppIconButtonStyle())
            .disabled(!session.canRedo)
            .help("Redo (⇧⌘Z)")
            .accessibilityLabel("Redo")

            Spacer(minLength: AppSpacing.lg)

            HoldToCompareButton(session: session)

            Button {
                session.revertToOriginal()
            } label: {
                Label("Revert to Original", systemImage: "arrow.counterclockwise")
                    .font(.appCaption)
            }
            .buttonStyle(AppLabeledButtonStyle(height: 26, horizontalPadding: AppSpacing.md))
            .disabled(session.recipe.isIdentity)
            .help("Remove every edit (crop, rotation, adjustments). Undoable until you close the editor.")
        }
    }
}

/// Press and hold to see the original; release to see the edit.
struct HoldToCompareButton: View {
    @Bindable var session: EditorSession
    @State private var isPressed = false

    var body: some View {
        Label("Hold to Compare", systemImage: "square.split.2x1")
            .font(.appCaption)
            .foregroundStyle(session.isComparing ? Color.appAccent : Color.appPrimaryText)
            .padding(.horizontal, AppSpacing.md)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(session.isComparing ? Color.appAccent.opacity(0.15) : Color.appElevatedSurface.opacity(0.6))
            )
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(Color.appControlBorder, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !session.isComparing { session.isComparing = true } }
                    .onEnded { _ in session.isComparing = false }
            )
            .help("Hold to see the original")
            .accessibilityLabel("Compare with original")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { session.isComparing.toggle() }
            .disabled(session.baseImage == nil)
    }
}
