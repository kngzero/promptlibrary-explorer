import SwiftUI

/// Library ▸ Prompt Builder…: compose a prompt from free text, snippets and
/// phrases found in the library, tune SD weights, add a negative prompt and a
/// parameter block, preview it in every copy format, copy, save as a snippet
/// or send it to a generator.
struct PromptBuilderView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let request: PromptBuilderRequest

    @State private var draft: PromptDraft
    @State private var previewFormat: PromptCopyFormat = .stableDiffusion
    @State private var sourceTab: SourceTab = .snippets
    @State private var snippetCategory: String = ""
    @State private var snippetQuery = ""
    @State private var snippets: [PromptSnippet] = []
    @State private var libraryQuery = ""
    @State private var libraryPhrases: [String] = []
    @State private var isSearchingLibrary = false
    @State private var sendRequest: GeneratorSendRequest?
    @FocusState private var libraryFieldFocused: Bool
    @FocusState private var snippetFieldFocused: Bool

    private enum SourceTab: String, CaseIterable, Identifiable {
        case snippets = "Snippets"
        case library = "Library"
        var id: String { rawValue }
    }

    init(request: PromptBuilderRequest) {
        self.request = request
        _draft = State(initialValue: request.draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Prompt Builder",
                subtitle: request.sourceName.map { "Started from \($0)" } ?? "Compose a prompt from text, snippets and library phrases",
                systemImage: "hammer",
                onClose: close
            )

            HStack(spacing: 0) {
                sourcesPane
                    .frame(width: 250)
                Rectangle().fill(Color.appBorder).frame(width: 1)
                ScrollView {
                    composePane.padding(AppSpacing.xl)
                }
                .frame(maxWidth: .infinity)
                Rectangle().fill(Color.appBorder).frame(width: 1)
                previewPane
                    .frame(width: 320)
            }
            .frame(maxHeight: .infinity)

            FeatureSheetFooter {
                Button {
                    saveSnippet()
                } label: {
                    Label("Save as Snippet", systemImage: "text.badge.star")
                }
                .buttonStyle(AppLabeledButtonStyle())
                .disabled(trimmedPrompt.isEmpty)

                Button("Clear") { draft = PromptDraft() }
                    .buttonStyle(AppLabeledButtonStyle())
                    .disabled(draft == PromptDraft())

                Spacer()

                Menu {
                    Button("Send to A1111 / Forge…") { send(.a1111) }
                        .disabled(trimmedPrompt.isEmpty)
                    Button("Re-run in ComfyUI…") { send(.comfyUI) }
                        .disabled(draft.comfyGraphJSON == nil)
                } label: {
                    Label("Send to Generator", systemImage: "paperplane")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(draft.comfyGraphJSON == nil
                      ? "Send the prompt and parameters to Automatic1111 / Forge. ComfyUI needs a file with an embedded API graph."
                      : "Send to Automatic1111 / Forge, or re-run the source file's ComfyUI graph with this prompt.")

                Button {
                    copy(previewFormat)
                } label: {
                    Label("Copy \(previewFormat.title)", systemImage: "doc.on.doc")
                }
                .buttonStyle(AppPrimaryButtonStyle())
                .disabled(trimmedPrompt.isEmpty)
            }
        }
        .frame(width: 1080, height: 720)
        .background(Color.appBackground)
        .onAppear(perform: reloadSnippets)
        .sheet(item: $sendRequest) { request in
            GeneratorSendView(request: request)
                .environment(vm)
        }
    }

    private var trimmedPrompt: String { draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Sources (snippets / library phrases)

    private var sourcesPane: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Picker("Source", selection: $sourceTab) {
                ForEach(SourceTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch sourceTab {
            case .snippets: snippetsList
            case .library: libraryList
            }
        }
        .padding(AppSpacing.lg)
        .background(Color.appSidebarBackground)
    }

    private var snippetsList: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            FeatureSearchField(placeholder: "Filter snippets", text: $snippetQuery, isFocused: $snippetFieldFocused)
                .onChange(of: snippetQuery) { _, _ in reloadSnippets() }
            let categories = SnippetService.shared.categories
            if !categories.isEmpty {
                Picker("Category", selection: $snippetCategory) {
                    Text("All Categories").tag("")
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .onChange(of: snippetCategory) { _, _ in reloadSnippets() }
            }
            if snippets.isEmpty {
                Text(SnippetService.shared.all().isEmpty
                     ? "No snippets yet. Save one from the details panel or with Save as Snippet below."
                     : "No snippets match.")
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppSpacing.xs) {
                        ForEach(snippets) { snippet in
                            SourceRow(title: snippet.title, detail: snippet.text, caption: snippet.category) {
                                insert(snippet.text)
                            }
                            .draggable(snippet.text)
                        }
                    }
                }
                Text("Click to add, or drag into the prompt.")
                    .font(.appFootnote)
                    .foregroundStyle(Color.appMuted)
            }
        }
    }

    private var libraryList: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            FeatureSearchField(placeholder: "Find a phrase in the library", text: $libraryQuery, isFocused: $libraryFieldFocused) {
                searchLibrary()
            }
            .onChange(of: libraryQuery) { _, _ in searchLibrary() }
            if isSearchingLibrary {
                ProgressView().controlSize(.small)
            }
            if libraryPhrases.isEmpty {
                Text(libraryQuery.isEmpty
                     ? "Search the library index for a word or phrase, then click a result to add it."
                     : (isSearchingLibrary ? "" : "No phrases found. Reindex the library if it's new (Library ▸ Reindex Library)."))
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppSpacing.xs) {
                        ForEach(libraryPhrases, id: \.self) { phrase in
                            SourceRow(title: phrase, detail: nil, caption: nil) { insert(phrase) }
                                .draggable(phrase)
                        }
                    }
                }
            }
        }
        .task(id: libraryQuery) {
            // Debounced search against the library index.
            let query = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { libraryPhrases = []; isSearchingLibrary = false; return }
            isSearchingLibrary = true
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let hits = await LibraryIndexService.shared.search(query, under: vm.explorerRootPath, limit: 60)
            guard !Task.isCancelled else { return }
            var seen = Set<String>()
            libraryPhrases = hits.flatMap { PromptBuilderService.phrases(fromSnippet: $0.snippet) }
                .filter { seen.insert($0.lowercased()).inserted }
                .prefix(80)
                .map { $0 }
            isSearchingLibrary = false
        }
    }

    // MARK: Compose

    private var composePane: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            fieldLabel("Prompt", systemImage: "text.quote")
            PromptTextEditor(placeholder: "Describe the image, phrases separated by commas…", text: $draft.prompt, minHeight: 130)

            weightsSection

            fieldLabel("Negative Prompt", systemImage: "minus.circle")
            PromptTextEditor(placeholder: "What to avoid (optional)", text: $draft.negative, minHeight: 60)

            fieldLabel("Parameters", systemImage: "slider.horizontal.3")
            Grid(alignment: .leading, horizontalSpacing: AppSpacing.md, verticalSpacing: AppSpacing.md) {
                GridRow {
                    paramField("Model", text: $draft.model, prompt: "checkpoint").gridCellColumns(2)
                    paramField("Sampler", text: $draft.sampler, prompt: "Euler a")
                }
                GridRow {
                    paramField("Steps", text: $draft.steps, prompt: "20")
                    paramField("CFG", text: $draft.cfg, prompt: "7")
                    HStack(spacing: AppSpacing.xs) {
                        paramField("Seed", text: $draft.seed, prompt: "random")
                        Button {
                            draft.seed = String(Int64.random(in: 0...4_294_967_295))
                        } label: {
                            Image(systemName: "dice")
                                .font(.appCallout)
                        }
                        .buttonStyle(AppIconButtonStyle(width: 24, height: 24, cornerRadius: AppRadius.sm))
                        .padding(.top, 14)
                        .help("Random Seed")
                        .accessibilityLabel("Random Seed")
                    }
                }
                GridRow {
                    paramField("Width", text: $draft.width, prompt: "1024")
                    paramField("Height", text: $draft.height, prompt: "1024")
                    Menu("Size") {
                        ForEach(["512×512", "768×768", "1024×1024", "832×1216", "1216×832", "896×1152", "1152×896", "1344×768", "768×1344"], id: \.self) { size in
                            Button(size) {
                                let parts = size.split(separator: "×")
                                draft.width = String(parts[0])
                                draft.height = String(parts[1])
                            }
                        }
                    }
                    .fixedSize()
                    .padding(.top, 14)
                }
            }
        }
    }

    @ViewBuilder
    private var weightsSection: some View {
        let phrases = PromptBuilderService.phrases(in: draft.prompt)
        if !phrases.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack {
                    Text("Weights")
                        .font(.appCaptionEmphasis)
                        .foregroundStyle(Color.appMuted)
                    Text("(phrase:1.2) syntax for Stable Diffusion")
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                    Spacer()
                    if phrases.contains(where: { abs($0.weight - 1) > 0.001 }) {
                        Button("Reset Weights") { draft.prompt = PromptBuilderService.stripWeights(draft.prompt) }
                            .buttonStyle(AppLabeledButtonStyle(height: 22, horizontalPadding: AppSpacing.sm))
                            .font(.appCaption)
                    }
                }
                PromptFlowLayout(spacing: AppSpacing.xs, lineSpacing: AppSpacing.xs) {
                    ForEach(Array(phrases.enumerated()), id: \.offset) { index, phrase in
                        WeightChip(
                            phrase: phrase,
                            decrease: { draft.prompt = PromptBuilderService.adjustWeight(by: -PromptBuilderService.weightStep, forPhraseAt: index, in: draft.prompt) },
                            increase: { draft.prompt = PromptBuilderService.adjustWeight(by: PromptBuilderService.weightStep, forPhraseAt: index, in: draft.prompt) }
                        )
                    }
                }
            }
        }
    }

    private func fieldLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.appHeadline)
            .foregroundStyle(Color.appPrimaryText)
    }

    private func paramField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(title)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .font(.appCallout)
                .labelsHidden()
        }
    }

    // MARK: Preview

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Preview")
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)
            Picker("Format", selection: $previewFormat) {
                ForEach(PromptCopyFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .labelsHidden()

            ScrollView {
                Text(trimmedPrompt.isEmpty ? "The prompt appears here as you type." : PromptBuilderService.format(draft, as: previewFormat))
                    .font(previewFormat == .json ? .appMono : .appCallout)
                    .foregroundStyle(trimmedPrompt.isEmpty ? Color.appMuted : Color.appPrimaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppSpacing.md)
            }
            .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.appSurface))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(Color.appBorder, lineWidth: 1))

            if previewFormat == .midjourney || previewFormat == .dalle {
                Text("\(previewFormat.title) doesn't read SD weights, so they're left out here.")
                    .font(.appFootnote)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Copy as")
                .font(.appCaptionEmphasis)
                .foregroundStyle(Color.appMuted)
            PromptFlowLayout(spacing: AppSpacing.xs, lineSpacing: AppSpacing.xs) {
                ForEach(PromptCopyFormat.allCases) { format in
                    Button(format.title) { copy(format) }
                        .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.sm))
                        .font(.appCaption)
                        .disabled(trimmedPrompt.isEmpty)
                }
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Actions

    private func insert(_ phrase: String) {
        draft.prompt = PromptBuilderService.appendPhrase(phrase, to: draft.prompt)
    }

    private func reloadSnippets() {
        let matches = SnippetService.shared.search(snippetQuery)
        snippets = snippetCategory.isEmpty
            ? matches
            : matches.filter { $0.category.caseInsensitiveCompare(snippetCategory) == .orderedSame }
    }

    private func searchLibrary() {
        // The .task(id: libraryQuery) above does the work; submitting re-runs it immediately.
        if libraryQuery.isEmpty { libraryPhrases = [] }
    }

    private func copy(_ format: PromptCopyFormat) {
        guard !trimmedPrompt.isEmpty else { return }
        ClipboardService.copyString(PromptBuilderService.format(draft, as: format))
        vm.showToast("Copied as \(format.title)", type: .success)
    }

    private func saveSnippet() {
        guard !trimmedPrompt.isEmpty else { return }
        let snippet = SnippetService.shared.add(title: "", text: trimmedPrompt, category: "Builder")
        reloadSnippets()
        vm.showToast("Saved snippet \"\(snippet.title)\"", type: .success)
    }

    private func send(_ kind: GeneratorKind) {
        let name = draft.sourcePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Prompt Builder"
        sendRequest = GeneratorSendRequest(
            kind: kind,
            sourcePath: draft.sourcePath,
            sourceName: name,
            prompt: draft.prompt,
            negative: draft.negative,
            parameters: draft.parameters,
            comfyGraphJSON: draft.comfyGraphJSON,
            comfyWorkflowJSON: nil,
            fallbackOutputFolder: vm.selectedFolderPath?.appendingPathComponent(PromptA1111.outputFolderName, isDirectory: true)
        )
    }

    private func close() {
        vm.promptWorkflows.builderRequest = nil
        dismiss()
    }
}

// MARK: - Rows

private struct SourceRow: View {
    let title: String
    let detail: String?
    let caption: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Image(systemName: "plus.circle")
                    .font(.appCaption)
                    .foregroundStyle(isHovered ? Color.appAccent : Color.appMuted)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(title)
                        .font(.appCallout)
                        .foregroundStyle(Color.appPrimaryText)
                        .lineLimit(2)
                    if let detail, detail != title {
                        Text(FeatureText.truncated(detail, limit: 90))
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                            .lineLimit(2)
                    }
                    if let caption, !caption.isEmpty {
                        Text(caption)
                            .font(.appMicro)
                            .foregroundStyle(Color.appMuted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(AppSpacing.sm)
            .background(FeatureRowBackground(isSelected: false, isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Add to the prompt")
    }
}

private struct WeightChip: View {
    let phrase: PromptPhrase
    let decrease: () -> Void
    let increase: () -> Void

    private var isWeighted: Bool { abs(phrase.weight - 1) > 0.001 }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: decrease) {
                Image(systemName: "minus").font(.appIcon(9, weight: .bold))
            }
            .buttonStyle(AppSegmentButtonStyle(width: 20, height: 20))
            .help("Less weight")
            .accessibilityLabel("Less weight for \(phrase.text)")
            .disabled(phrase.weight <= PromptBuilderService.weightRange.lowerBound + 0.001)

            Text(phrase.text)
                .font(.appCaption)
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
                .frame(maxWidth: 180)
            if isWeighted {
                Text(PromptBuilderService.formatWeight(phrase.weight))
                    .font(.appCaptionEmphasis.monospacedDigit())
                    .foregroundStyle(phrase.weight > 1 ? Color.labelGreenText : Color.labelOrangeText)
                    .padding(.leading, AppSpacing.xs)
            }

            Button(action: increase) {
                Image(systemName: "plus").font(.appIcon(9, weight: .bold))
            }
            .buttonStyle(AppSegmentButtonStyle(width: 20, height: 20))
            .help("More weight")
            .accessibilityLabel("More weight for \(phrase.text)")
            .disabled(phrase.weight >= PromptBuilderService.weightRange.upperBound - 0.001)
        }
        .padding(.horizontal, AppSpacing.xxs)
        .background(Capsule().fill(isWeighted ? Color.appAccent.opacity(0.12) : Color.appElevatedSurface))
        .overlay(Capsule().strokeBorder(isWeighted ? Color.appAccent.opacity(0.35) : Color.appBorder, lineWidth: 1))
    }
}
