import SwiftUI

/// Batch metadata editor for embedding metadata into multiple selected images at once.
struct BatchMetadataEditorView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var model = ""
    @State private var isProcessing = false
    @State private var processedCount = 0

    private var targetFiles: [FileEntry] {
        vm.selectedEmbeddableImages
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Batch Edit Metadata")
                    .font(.appTitle)
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
                Text("\(targetFiles.count) file(s) selected")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
            .padding(AppSpacing.xl)
            .background(Color.appSurface)

            Divider().background(Color.appBorder)

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    // File list preview
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("Target Files")
                            .font(.appCaptionEmphasis)
                            .foregroundStyle(Color.appMuted)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: AppSpacing.sm) {
                                ForEach(targetFiles) { file in
                                    Text(file.name)
                                        .font(.appFootnote)
                                        .foregroundStyle(Color.appPrimaryText)
                                        .padding(.horizontal, AppSpacing.md)
                                        .padding(.vertical, AppSpacing.xs)
                                        .background(Color.appSurface)
                                        .cornerRadius(AppRadius.sm)
                                }
                            }
                        }
                    }

                    Divider().background(Color.appBorder)

                    // Prompt
                    fieldSection(title: "Prompt", placeholder: "Enter prompt text to embed...", text: $prompt, height: 100)

                    // Negative Prompt
                    fieldSection(title: "Negative Prompt", placeholder: "Enter negative prompt (optional)...", text: $negativePrompt, height: 60)

                    // Model
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Model")
                            .font(.appCaptionEmphasis)
                            .foregroundStyle(Color.appMuted)
                        TextField("Model name (optional)", text: $model)
                            .textFieldStyle(.roundedBorder)
                            .font(.appBody)
                    }

                    Text("Only non-empty fields will be written. Existing metadata will be overwritten for specified fields.")
                        .font(.appFootnote)
                        .foregroundStyle(Color.appMuted)
                        .padding(.top, AppSpacing.xs)
                }
                .padding(AppSpacing.xl)
            }

            Divider().background(Color.appBorder)

            // Actions
            HStack {
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing \(processedCount)/\(targetFiles.count)...")
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)

                Button("Apply to All") {
                    Task { await applyMetadata() }
                }
                .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                .disabled(prompt.isEmpty && negativePrompt.isEmpty && model.isEmpty)
                .disabled(isProcessing)
            }
            .padding(AppSpacing.xl)
            .background(Color.appSurface)
        }
        .frame(width: 520, height: 520)
        .background(Color.appBackground)
    }

    @ViewBuilder
    private func fieldSection(title: String, placeholder: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(title)
                .font(.appCaptionEmphasis)
                .foregroundStyle(Color.appMuted)
            TextEditor(text: text)
                .font(.appBody)
                .foregroundStyle(Color.appPrimaryText)
                .scrollContentBackground(.hidden)
                .padding(AppSpacing.md)
                .frame(height: height)
                .background(Color.appSurface)
                .cornerRadius(AppRadius.md)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .strokeBorder(Color.appBorder, lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(.appBody)
                            .foregroundStyle(Color.appMuted.opacity(0.5))
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, AppSpacing.lg)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private func applyMetadata() async {
        isProcessing = true
        processedCount = 0

        // Blank fields mean "keep what's there": each file's existing prompt, seed, steps
        // and other parameters are merged with only the fields filled in here.
        let metadata = ImageMetadataWriter.PromptMetadata(
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            negativePrompt: negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            steps: "",
            sampler: "",
            cfgScale: "",
            seed: ""
        )
        let urls = targetFiles.map(\.url)

        let failures = await Task.detached(priority: .userInitiated) { () -> [(name: String, message: String)] in
            var failures: [(name: String, message: String)] = []
            for url in urls {
                do {
                    try ImageMetadataWriter.write(metadata, to: url, mode: .mergeNonEmpty)
                } catch {
                    failures.append((url.lastPathComponent, error.localizedDescription))
                }
                await MainActor.run { processedCount += 1 }
            }
            return failures
        }.value

        // Refresh caches
        await ImageMetadataParser.shared.clearCache()
        ThumbnailService.shared.clearCache()

        isProcessing = false

        let succeeded = urls.count - failures.count
        if failures.isEmpty {
            vm.showToast("Metadata applied to \(succeeded) file(s)", type: .success)
        } else if let first = failures.first, failures.count == 1, succeeded == 0 {
            vm.showToast("Couldn't update \(first.name): \(first.message)", type: .error)
        } else {
            let detail = failures.first.map { " First error (\($0.name)): \($0.message)" } ?? ""
            vm.showToast("Metadata applied to \(succeeded) of \(urls.count) file(s); \(failures.count) failed.\(detail)", type: .error)
        }
        dismiss()
    }
}
