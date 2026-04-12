import SwiftUI

/// A sheet for adding or editing prompt metadata that gets embedded into an image file.
struct MetadataEditorView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    let imagePath: String

    @State private var prompt: String = ""
    @State private var negativePrompt: String = ""
    @State private var model: String = ""
    @State private var steps: String = ""
    @State private var sampler: String = ""
    @State private var cfgScale: String = ""
    @State private var seed: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// If we're editing existing metadata, pre-populate from the current entry.
    var existingEntry: PromptEntry?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Embed Prompt Metadata")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.appMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(Color.appBorder)

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    editorField(label: "Prompt", text: $prompt, isMultiline: true, placeholder: "Describe the image…")
                    editorField(label: "Negative Prompt", text: $negativePrompt, isMultiline: true, placeholder: "What to exclude…")

                    Divider().background(Color.appBorder.opacity(0.5))

                    Text("Generation Parameters")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.appMuted)

                    editorField(label: "Model", text: $model, placeholder: "e.g. sd_xl_base_1.0")

                    HStack(spacing: 12) {
                        editorField(label: "Steps", text: $steps, placeholder: "e.g. 30")
                        editorField(label: "CFG Scale", text: $cfgScale, placeholder: "e.g. 7.5")
                    }

                    HStack(spacing: 12) {
                        editorField(label: "Sampler", text: $sampler, placeholder: "e.g. Euler a")
                        editorField(label: "Seed", text: $seed, placeholder: "e.g. 12345")
                    }

                    if let errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.system(size: 11))
                            Text(errorMessage)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                .padding(20)
            }

            Divider().background(Color.appBorder)

            // Footer
            HStack {
                Text(URL(fileURLWithPath: imagePath).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button {
                    saveMetadata()
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 60)
                    } else {
                        Text("Save")
                            .frame(width: 60)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 560)
        .background(Color.appSidebarBackground)
        .onAppear {
            prefillFromEntry()
        }
    }

    // MARK: - Field Builder

    @ViewBuilder
    private func editorField(label: String, text: Binding<String>, isMultiline: Bool = false, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.appMuted)

            if isMultiline {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: text)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 72, maxHeight: 120)
                        .padding(6)
                        .background(Color.appSurface.opacity(0.6))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.appBorder, lineWidth: 1)
                        )

                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appMuted.opacity(0.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(Color.appSurface.opacity(0.6))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.appBorder, lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Prefill

    private func prefillFromEntry() {
        guard let entry = existingEntry else { return }
        prompt = entry.prompt
        negativePrompt = entry.blindPrompt ?? ""

        if entry.generationInfo.model != "N/A" {
            model = entry.generationInfo.model
        }

        for field in entry.embeddedMetadata {
            let key = field.label.lowercased()
            if key.contains("steps") && steps.isEmpty { steps = field.value }
            else if key.contains("sampler") && sampler.isEmpty { sampler = field.value }
            else if (key.contains("cfg") || key.contains("guidance")) && cfgScale.isEmpty { cfgScale = field.value }
            else if key.contains("seed") && seed.isEmpty { seed = field.value }
        }
    }

    // MARK: - Save

    private func saveMetadata() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        let metadata = ImageMetadataWriter.PromptMetadata(
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            negativePrompt: negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            steps: steps.trimmingCharacters(in: .whitespacesAndNewlines),
            sampler: sampler.trimmingCharacters(in: .whitespacesAndNewlines),
            cfgScale: cfgScale.trimmingCharacters(in: .whitespacesAndNewlines),
            seed: seed.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let url = URL(fileURLWithPath: imagePath)

        Task {
            do {
                try ImageMetadataWriter.write(metadata, to: url)

                await MainActor.run {
                    vm.didEmbedMetadata(at: imagePath)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }
}
