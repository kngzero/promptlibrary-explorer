import AppKit
import SwiftUI

/// Re-run in ComfyUI / Send to A1111/Forge: options, then progress and the
/// result. Nothing is sent until the user presses the primary button.
struct GeneratorSendView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var model: GeneratorJobModel

    init(request: GeneratorSendRequest) {
        _model = State(initialValue: GeneratorJobModel(request: request))
    }

    private var request: GeneratorSendRequest { model.request }

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: request.kind == .comfyUI ? "Re-run in ComfyUI" : "Send to A1111 / Forge",
                subtitle: "\(request.sourceName) → \(model.serverDescription)",
                systemImage: request.kind == .comfyUI ? "point.3.connected.trianglepath.dotted" : "paperplane",
                closeTitle: model.phase == .finished ? "Done" : "Close",
                onClose: close
            )

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    if request.kind == .comfyUI, model.hasOnlyUIWorkflow {
                        uiWorkflowNotice
                    } else {
                        options
                    }
                    statusBlock
                }
                .padding(AppSpacing.xl)
            }
            .frame(maxHeight: .infinity)

            FeatureSheetFooter {
                Button("Server Settings…") { vm.openGeneratorSettings() }
                    .buttonStyle(AppLabeledButtonStyle())
                Spacer()
                if model.phase == .running {
                    Button("Cancel") { model.cancel() }
                        .buttonStyle(AppLabeledButtonStyle())
                }
                if !(request.kind == .comfyUI && model.hasOnlyUIWorkflow) {
                    Button(primaryTitle) { model.start() }
                        .buttonStyle(AppPrimaryButtonStyle())
                        .disabled(!model.canStart)
                }
            }
        }
        .frame(width: 560, height: request.kind == .comfyUI ? 480 : 560)
        .background(Color.appBackground)
        .onDisappear { model.tearDown() }
    }

    private var primaryTitle: String {
        switch (request.kind, model.phase) {
        case (.comfyUI, .finished): return "Queue Again"
        case (.comfyUI, _): return "Queue Prompt"
        case (.a1111, .finished): return "Generate Again"
        case (.a1111, _): return "Generate"
        }
    }

    // MARK: Options

    @ViewBuilder
    private var options: some View {
        @Bindable var model = model
        PromptSheetCard(title: "Options", systemImage: "slider.horizontal.3") {
            SettingsToggleRow(
                title: "New random seed",
                detail: request.kind == .comfyUI
                    ? "Replaces the sampler's seed (or the RandomNoise / primitive node feeding it)."
                    : "Sends seed −1 so A1111 picks one. Off: the file's seed \(request.parameters.seed ?? "(none, so random)").",
                isOn: $model.randomizeSeed
            )
            .disabled(model.phase == .running)

            if request.kind == .comfyUI {
                SettingsToggleRow(
                    title: "Edit the positive prompt",
                    detail: model.graphPrompt == nil
                        ? "No text encoder feeding the sampler's positive input was found in this graph."
                        : "Replaces the text of the CLIPTextEncode node feeding the sampler's positive input.",
                    isOn: $model.editPrompt
                )
                .disabled(model.phase == .running || model.graphPrompt == nil)
                if model.editPrompt {
                    PromptTextEditor(placeholder: "Positive prompt", text: $model.editedPrompt, minHeight: 110)
                }
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Prompt").font(.appCaptionEmphasis).foregroundStyle(Color.appMuted)
                    PromptTextEditor(placeholder: "Prompt", text: $model.editedPrompt, minHeight: 90)
                }
                parameterSummary
                SettingsToggleRow(
                    title: "Use the file's model",
                    detail: "Asks the server to switch to \(request.parameters.model ?? "the file's checkpoint") for this image, then switch back. Off: the server's current model.",
                    isOn: $model.useFileModel
                )
                .disabled(model.phase == .running || request.parameters.model == nil)
                outputFolderRow
            }
        }
    }

    private var parameterSummary: some View {
        let body = PromptA1111.request(prompt: model.editedPrompt, negative: request.negative, parameters: request.parameters, randomSeed: model.randomizeSeed)
        let items = [
            "\(body.width)×\(body.height)",
            "\(body.steps) steps",
            "CFG \(PromptBuilderService.formatWeight(body.cfg_scale))",
            body.sampler_name.map { "Sampler \($0)" + (body.scheduler.map { " \($0)" } ?? "") },
            body.seed >= 0 ? "Seed \(body.seed)" : "Random seed",
            request.negative.isEmpty ? nil : "Negative prompt",
        ].compactMap { $0 }
        return PromptFlowLayout {
            ForEach(items, id: \.self) { PromptChip(text: $0) }
        }
    }

    private var outputFolderRow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Save to").font(.appCaptionEmphasis).foregroundStyle(Color.appMuted)
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "folder")
                    .foregroundStyle(Color.appMuted)
                Text(model.outputFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Choose a folder")
                    .font(.appCallout)
                    .foregroundStyle(model.outputFolder == nil ? Color.appMuted : Color.appPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…", action: chooseFolder)
                    .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
                    .disabled(model.phase == .running)
            }
            Text("New files never overwrite existing ones; the folder is created if needed.")
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)
        }
    }

    private var uiWorkflowNotice: some View {
        PromptSheetCard(title: "Can't queue this file directly", systemImage: "exclamationmark.triangle") {
            Text("This file stores only ComfyUI's UI workflow, not the API graph that ComfyUI's /prompt endpoint queues. Copy the workflow, paste it into ComfyUI (or drop the image there) and queue it from ComfyUI.")
                .font(.appBody)
                .foregroundStyle(Color.appPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let json = request.comfyWorkflowJSON {
                    ClipboardService.copyString(json)
                    vm.showToast("ComfyUI workflow JSON copied", type: .success)
                }
            } label: {
                Label("Copy Workflow JSON", systemImage: "doc.on.doc")
            }
            .buttonStyle(AppPrimaryButtonStyle())
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusBlock: some View {
        switch model.phase {
        case .ready:
            if !model.status.isEmpty {
                SettingsResultBanner(message: model.status, tone: .info)
            }
        case .running:
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                if let progress = model.progress {
                    ProgressView(value: progress)
                        .tint(Color.appAccent)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(model.status)
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
            }
        case .finished:
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                SettingsResultBanner(message: model.status, tone: .success)
                if let id = model.queuedPromptID {
                    Button {
                        ClipboardService.copyString(id)
                        vm.showToast("Prompt id copied", type: .success)
                    } label: {
                        Label("Copy Prompt ID", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(AppLabeledButtonStyle())
                }
                if !model.savedURLs.isEmpty {
                    HStack(spacing: AppSpacing.sm) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(model.savedURLs)
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        .buttonStyle(AppLabeledButtonStyle())
                        Button {
                            let url = model.savedURLs[0]
                            close()
                            Task { await vm.revealFile(at: url) }
                        } label: {
                            Label("Show in Browser", systemImage: "square.grid.2x2")
                        }
                        .buttonStyle(AppLabeledButtonStyle())
                    }
                }
            }
        case .failed:
            SettingsResultBanner(message: model.errorMessage ?? "Something went wrong.", tone: .error)
        }
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Where should generated images be saved?"
        if let folder = model.outputFolder {
            panel.directoryURL = FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.outputFolder = url
        }
    }

    private func close() {
        model.tearDown()
        if vm.promptWorkflows.generatorRequest?.id == request.id {
            vm.promptWorkflows.generatorRequest = nil
        }
        dismiss()
    }
}
