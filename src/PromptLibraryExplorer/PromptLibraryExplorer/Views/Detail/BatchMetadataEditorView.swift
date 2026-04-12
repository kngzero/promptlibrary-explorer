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
            .padding(16)
            .background(Color.appSurface)

            Divider().background(Color.appBorder)

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // File list preview
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Target Files")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.appMuted)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(targetFiles) { file in
                                    Text(file.name)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.appPrimaryText)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.appSurface)
                                        .cornerRadius(6)
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.appMuted)
                        TextField("Model name (optional)", text: $model)
                            .textFieldStyle(.roundedBorder)
                            .font(.appBody)
                    }

                    Text("Only non-empty fields will be written. Existing metadata will be overwritten for specified fields.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appMuted)
                        .padding(.top, 4)
                }
                .padding(16)
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
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .disabled(prompt.isEmpty && negativePrompt.isEmpty && model.isEmpty)
                .disabled(isProcessing)
            }
            .padding(16)
            .background(Color.appSurface)
        }
        .frame(width: 520, height: 520)
        .background(Color.appBackground)
    }

    @ViewBuilder
    private func fieldSection(title: String, placeholder: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appMuted)
            TextEditor(text: text)
                .font(.appBody)
                .foregroundStyle(Color.appPrimaryText)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: height)
                .background(Color.appSurface)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.appBorder, lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(.appBody)
                            .foregroundStyle(Color.appMuted.opacity(0.5))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private func applyMetadata() async {
        isProcessing = true
        processedCount = 0

        let metadata = ImageMetadataWriter.PromptMetadata(
            prompt: prompt,
            negativePrompt: negativePrompt,
            model: model,
            steps: "",
            sampler: "",
            cfgScale: "",
            seed: ""
        )

        for file in targetFiles {
            do {
                try ImageMetadataWriter.write(metadata, to: file.url)
                processedCount += 1
            } catch {
                processedCount += 1
            }
        }

        // Refresh caches
        await ImageMetadataParser.shared.clearCache()
        ThumbnailService.shared.clearCache()

        isProcessing = false
        vm.showToast("Metadata applied to \(processedCount) file(s)", type: .success)
        dismiss()
    }
}
