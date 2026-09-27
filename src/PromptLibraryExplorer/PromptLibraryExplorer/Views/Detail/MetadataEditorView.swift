import SwiftUI

/// A sheet for editing metadata embedded into a supported media file.
struct MetadataEditorView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    let filePath: String

    @State private var prompt: String = ""
    @State private var negativePrompt: String = ""
    @State private var model: String = ""
    @State private var steps: String = ""
    @State private var sampler: String = ""
    @State private var cfgScale: String = ""
    @State private var seed: String = ""

    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var album: String = ""
    @State private var genre: String = ""
    @State private var trackNumber: String = ""
    @State private var date: String = ""
    @State private var comment: String = ""
    @State private var copyright: String = ""

    @State private var isSaving = false
    @State private var errorMessage: String?

    /// If we're editing existing metadata, pre-populate from the current entry.
    var existingEntry: PromptEntry?

    private var isAudioFile: Bool {
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        return ext == "mp3" || ext == "wav"
    }

    private var sheetTitle: String {
        isAudioFile ? "Edit Audio Tags" : "Edit Embedded Metadata"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sheetTitle)
                    .font(.appIcon(15, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.appIcon(16))
                        .foregroundStyle(Color.appMuted)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(Color.appBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    if isAudioFile {
                        audioForm
                    } else {
                        imageForm
                    }

                    if let errorMessage {
                        HStack(spacing: AppSpacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.appError)
                                .font(.appCaption)
                            Text(errorMessage)
                                .font(.appCallout)
                                .foregroundStyle(Color.appError)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.appError.opacity(0.1))
                        .cornerRadius(AppRadius.md)
                    }
                }
                .padding(20)
            }

            Divider().background(Color.appBorder)

            HStack {
                Text(URL(fileURLWithPath: filePath).lastPathComponent)
                    .font(.appCaption)
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
                .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                .disabled(!hasMetadataToSave || isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, AppSpacing.lg)
        }
        .frame(width: 540, height: isAudioFile ? 520 : 560)
        .background(Color.appSidebarBackground)
        .onAppear {
            prefillFromEntry()
        }
    }

    private var hasMetadataToSave: Bool {
        if isAudioFile {
            return [
                title,
                artist,
                album,
                genre,
                trackNumber,
                date,
                comment,
                copyright,
            ].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        return [
            prompt,
            negativePrompt,
            model,
            steps,
            sampler,
            cfgScale,
            seed,
        ].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    @ViewBuilder
    private var imageForm: some View {
        editorField(label: "Prompt", text: $prompt, isMultiline: true, placeholder: "Describe the media…")
        editorField(label: "Negative Prompt", text: $negativePrompt, isMultiline: true, placeholder: "What to exclude…")

        Divider().background(Color.appBorder.opacity(0.5))

        Text("Generation Parameters")
            .font(.appIcon(11, weight: .medium))
            .foregroundStyle(Color.appMuted)

        editorField(label: "Model", text: $model, placeholder: "e.g. sd_xl_base_1.0")

        HStack(spacing: AppSpacing.lg) {
            editorField(label: "Steps", text: $steps, placeholder: "e.g. 30")
            editorField(label: "CFG Scale", text: $cfgScale, placeholder: "e.g. 7.5")
        }

        HStack(spacing: AppSpacing.lg) {
            editorField(label: "Sampler", text: $sampler, placeholder: "e.g. Euler a")
            editorField(label: "Seed", text: $seed, placeholder: "e.g. 12345")
        }
    }

    @ViewBuilder
    private var audioForm: some View {
        Text("Standard Audio Tags")
            .font(.appIcon(11, weight: .medium))
            .foregroundStyle(Color.appMuted)

        editorField(label: "Title", text: $title, placeholder: "Track title")

        HStack(spacing: AppSpacing.lg) {
            editorField(label: "Artist", text: $artist, placeholder: "Primary artist")
            editorField(label: "Album", text: $album, placeholder: "Release or album")
        }

        HStack(spacing: AppSpacing.lg) {
            editorField(label: "Genre", text: $genre, placeholder: "e.g. Ambient")
            editorField(label: "Track Number", text: $trackNumber, placeholder: "e.g. 3")
        }

        HStack(spacing: AppSpacing.lg) {
            editorField(label: "Date", text: $date, placeholder: "e.g. 2026")
            editorField(label: "Copyright", text: $copyright, placeholder: "Rights statement")
        }

        Divider().background(Color.appBorder.opacity(0.5))

        editorField(label: "Comment", text: $comment, isMultiline: true, placeholder: "Notes about the recording…")
    }

    // MARK: - Field Builder

    @ViewBuilder
    private func editorField(label: String, text: Binding<String>, isMultiline: Bool = false, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(label)
                .font(.appIcon(11, weight: .medium))
                .foregroundStyle(Color.appMuted)

            if isMultiline {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: text)
                        .font(.appBody)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 72, maxHeight: 120)
                        .padding(AppSpacing.sm)
                        .background(Color.appSurface.opacity(0.6))
                        .cornerRadius(AppRadius.md)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.md)
                                .strokeBorder(Color.appBorder, lineWidth: 1)
                        )

                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(.appBody)
                            .foregroundStyle(Color.appMuted.opacity(0.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, AppSpacing.lg)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(.appBody)
                    .padding(AppSpacing.md)
                    .background(Color.appSurface.opacity(0.6))
                    .cornerRadius(AppRadius.md)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .strokeBorder(Color.appBorder, lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Prefill

    private func prefillFromEntry() {
        if isAudioFile {
            prefillAudioTags()
        } else {
            prefillImageMetadata()
        }
    }

    private func prefillImageMetadata() {
        prefillImageMetadataFromEntry()

        // Saving replaces these fields, so fill anything the entry didn't provide straight from
        // the file's embedded parameters; otherwise a blank field would erase an existing value.
        guard let embedded = ImageMetadataWriter.existingMetadata(at: URL(fileURLWithPath: filePath)) else { return }
        if prompt.isEmpty { prompt = embedded.prompt }
        if negativePrompt.isEmpty { negativePrompt = embedded.negativePrompt }
        if model.isEmpty { model = embedded.model }
        if steps.isEmpty { steps = embedded.steps }
        if sampler.isEmpty { sampler = embedded.sampler }
        if cfgScale.isEmpty { cfgScale = embedded.cfgScale }
        if seed.isEmpty { seed = embedded.seed }
    }

    private func prefillImageMetadataFromEntry() {
        guard let entry = existingEntry else { return }
        prompt = entry.prompt
        negativePrompt = entry.blindPrompt ?? ""

        if entry.generationInfo.model != "N/A" {
            model = entry.generationInfo.model
        }

        for field in entry.embeddedMetadata {
            let key = canonicalKey(field.label)
            if key == "steps", steps.isEmpty { steps = field.value }
            else if key == "sampler", sampler.isEmpty { sampler = field.value }
            else if key == "cfgscale" || key == "guidance", cfgScale.isEmpty { cfgScale = field.value }
            else if key == "seed", seed.isEmpty { seed = field.value }
        }
    }

    private func prefillAudioTags() {
        guard let entry = existingEntry else { return }

        for field in entry.embeddedMetadata {
            switch canonicalKey(field.label) {
            case "title":
                if title.isEmpty { title = field.value }
            case "artist":
                if artist.isEmpty { artist = field.value }
            case "album":
                if album.isEmpty { album = field.value }
            case "genre":
                if genre.isEmpty { genre = field.value }
            case "tracknumber", "track":
                if trackNumber.isEmpty { trackNumber = field.value }
            case "date", "year":
                if date.isEmpty { date = field.value }
            case "comment":
                if comment.isEmpty { comment = field.value }
            case "copyright":
                if copyright.isEmpty { copyright = field.value }
            default:
                continue
            }
        }
    }

    // MARK: - Save

    private func saveMetadata() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        let url = URL(fileURLWithPath: filePath)

        Task {
            do {
                if isAudioFile {
                    let metadata = AudioTagMetadata(
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
                        album: album.trimmingCharacters(in: .whitespacesAndNewlines),
                        genre: genre.trimmingCharacters(in: .whitespacesAndNewlines),
                        trackNumber: trackNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                        date: date.trimmingCharacters(in: .whitespacesAndNewlines),
                        comment: comment.trimmingCharacters(in: .whitespacesAndNewlines),
                        copyright: copyright.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    try await Task.detached(priority: .userInitiated) {
                        try AudioMetadataWriter.write(metadata, to: url)
                    }.value
                } else {
                    let metadata = ImageMetadataWriter.PromptMetadata(
                        prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                        negativePrompt: negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                        model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                        steps: steps.trimmingCharacters(in: .whitespacesAndNewlines),
                        sampler: sampler.trimmingCharacters(in: .whitespacesAndNewlines),
                        cfgScale: cfgScale.trimmingCharacters(in: .whitespacesAndNewlines),
                        seed: seed.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    // Form values replace prompt/negative and the five known keys; every other
                    // parameter already in the file (Size, VAE, hashes, …) is preserved.
                    try await Task.detached(priority: .userInitiated) {
                        try ImageMetadataWriter.write(metadata, to: url, mode: .replace)
                    }.value
                }

                await MainActor.run {
                    vm.didEmbedMetadata(at: filePath)
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

    private func canonicalKey(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
