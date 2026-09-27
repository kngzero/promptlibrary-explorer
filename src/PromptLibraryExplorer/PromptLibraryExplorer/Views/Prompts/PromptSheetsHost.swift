import SwiftUI

/// Presents the prompt-workflow sheets (lineage, builder, statistics, send to
/// generator) on the main window. Applied once in the App file, so
/// MainContentView stays untouched.
struct PromptSheetsHost: ViewModifier {
    @Environment(ExplorerViewModel.self) private var vm
    @Bindable private var controller = PromptWorkflowController.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $controller.lineageRequest) { request in
                PromptLineageView(request: request)
                    .environment(vm)
            }
            .sheet(item: $controller.builderRequest) { request in
                PromptBuilderView(request: request)
                    .environment(vm)
            }
            .sheet(item: $controller.statisticsRequest) { request in
                PromptStatisticsView(request: request)
                    .environment(vm)
            }
            .sheet(item: $controller.generatorRequest) { request in
                GeneratorSendView(request: request)
                    .environment(vm)
            }
    }
}

extension View {
    func promptSheetsHost() -> some View {
        modifier(PromptSheetsHost())
    }
}

// MARK: - Context menu items

/// Prompt items for a grid tile / list row context menu. `targets` is the
/// selection as it will be after the right-clicked item is selected.
struct PromptItemMenuItems: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: FileEntry
    let targets: [FileEntry]
    /// Makes the right-clicked item part of the selection first.
    let ensureSelected: () -> Void

    var body: some View {
        if !item.isDirectory {
            if vm.lineagePaths(for: targets).count >= 2 {
                Button("Show Prompt Lineage") {
                    ensureSelected()
                    vm.showPromptLineage(for: targets)
                }
            }
            if targets.count == 1 {
                Button("Open in Prompt Builder") { vm.openPromptBuilder(from: item) }
                if vm.canSendToGenerator(.comfyUI, item: item) || vm.canSendToGenerator(.a1111, item: item) {
                    Menu("Send to Generator") {
                        Button("Re-run in ComfyUI…") { vm.sendToGenerator(.comfyUI, item: item) }
                            .disabled(!vm.canSendToGenerator(.comfyUI, item: item))
                        Button("Send to A1111 / Forge…") { vm.sendToGenerator(.a1111, item: item) }
                            .disabled(!vm.canSendToGenerator(.a1111, item: item))
                    }
                }
            }
        }
    }
}

// MARK: - Details panel card

/// "Prompt Tools" card in the details panel: builder, lineage, generators.
struct PromptWorkflowDetailCard: View {
    @Environment(ExplorerViewModel.self) private var vm
    let entry: PromptEntry

    private var item: FileEntry? {
        guard let path = entry.sourcePath else { return nil }
        return vm.listingSourceContents.first(where: { $0.path == path })
            ?? FileEntry(url: URL(fileURLWithPath: path), isDirectory: false)
    }

    private var hasPromptData: Bool {
        !entry.prompt.isEmpty || entry.comfyPromptJSON != nil || entry.comfyWorkflowJSON != nil
    }

    var body: some View {
        if let item, hasPromptData, entry.artOfficialDocument == nil {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("Prompt Tools")
                    .font(.appIcon(11, weight: .medium))
                    .foregroundStyle(Color.appMuted)
                PromptFlowLayout(spacing: AppSpacing.sm, lineSpacing: AppSpacing.sm) {
                    Button {
                        vm.openPromptBuilder(from: item)
                    } label: {
                        Label("Prompt Builder", systemImage: "hammer").font(.appCaption)
                    }
                    .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
                    .help("Open this prompt in the Prompt Builder")

                    if vm.canShowPromptLineage {
                        Button {
                            vm.showPromptLineage()
                        } label: {
                            Label("Lineage", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(.appCaption)
                        }
                        .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
                        .help("Show Prompt Lineage for the selected files")
                    }

                    if entry.comfyPromptJSON != nil || entry.comfyWorkflowJSON != nil {
                        Button {
                            vm.sendToGenerator(.comfyUI, item: item)
                        } label: {
                            Label("Re-run in ComfyUI", systemImage: "point.3.connected.trianglepath.dotted").font(.appCaption)
                        }
                        .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
                        .help("Queue this file's ComfyUI graph again, optionally with a new seed or prompt")
                    }

                    if !entry.prompt.isEmpty, vm.canSendToGenerator(.a1111, item: item) {
                        Button {
                            vm.sendToGenerator(.a1111, item: item)
                        } label: {
                            Label("Send to A1111", systemImage: "paperplane").font(.appCaption)
                        }
                        .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
                        .help("Generate with Automatic1111 / Forge from this prompt and its parameters")
                    }
                }
                .padding(AppSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.appSurface.opacity(0.6))
                .cornerRadius(AppRadius.lg)
            }
        }
    }
}
