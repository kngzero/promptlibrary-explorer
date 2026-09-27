import SwiftUI

/// Details-panel cards for one file: its version stack, the text recognised in it, and
/// suggested tags (click a chip to add one; nothing is added on its own).
struct ImageAnalysisDetailsSection: View {
    @Environment(ExplorerViewModel.self) private var vm
    let path: String

    @State private var record: ImageTextRecord?
    @State private var hasLoaded = false
    @State private var suggestions: [TagSuggestion] = []
    @State private var isAnalyzing = false

    private var controller: ImageTextController { .shared }
    private var isImage: Bool { FileHelpers.isImageFile((path as NSString).lastPathComponent) }

    private var loadKey: String {
        "\(path)|\(controller.recordsRevision)|\(vm.tagsForFile(at: path).map(\.id))|\(controller.suggestTagsEnabled)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            StackMembershipCard(path: path)

            if isImage {
                if controller.recognizeTextEnabled || record?.hasText == true {
                    AnalysisDetailCard(title: "Text in Image") { textContent }
                }
                if controller.suggestTagsEnabled, hasLoaded, !suggestions.isEmpty {
                    suggestionsRow
                }
            }
        }
        .task(id: loadKey) { await load() }
    }

    // MARK: Text

    @ViewBuilder
    private var textContent: some View {
        if let text = record?.text, !text.isEmpty {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Text(text)
                    .font(.appBody)
                    .foregroundStyle(Color.appPrimaryText.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    ClipboardService.copyString(text)
                    vm.showToast("Text copied", type: .success)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.appCaption)
                }
                .buttonStyle(AppIconButtonStyle(width: 22, height: 22, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                .help("Copy Text")
                .accessibilityLabel("Copy text in image")
            }
        } else if record?.text != nil {
            Text("No text found in this image.")
                .font(.appCallout)
                .foregroundStyle(Color.appMuted)
        } else if hasLoaded {
            HStack(spacing: AppSpacing.md) {
                Text(pendingMessage)
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    Task { await analyzeNow() }
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        if isAnalyzing { ProgressView().controlSize(.mini) }
                        Text(isAnalyzing ? "Analysing…" : "Analyse Now")
                    }
                }
                .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md, cornerRadius: AppRadius.sm))
                .font(.appCaption)
                .disabled(isAnalyzing)
                .help("Recognise text and suggest tags for this image now")
            }
        }
    }

    private var pendingMessage: String {
        switch controller.state {
        case .analyzing, .waiting: return "Not analysed yet — the background pass will get to it."
        case .paused: return "Not analysed yet — paused with the visual index."
        case .stopped: return "Not analysed — the visual index is stopped."
        default: return "Not analysed yet."
        }
    }

    // MARK: Suggestions

    private var suggestionsRow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Text("Suggested")
                    .font(.appCalloutEmphasis)
                    .foregroundStyle(Color.appMuted)
                Spacer(minLength: 0)
                Button("Add All") {
                    vm.addSuggestedTags(suggestions.map(\.name), to: [path])
                }
                .buttonStyle(AppLabeledButtonStyle(height: 22, horizontalPadding: AppSpacing.md, cornerRadius: AppRadius.sm))
                .font(.appCaption)
                .help("Add every suggested tag to this file")
            }
            SuggestionChipFlow(spacing: AppSpacing.xs) {
                ForEach(suggestions) { suggestion in
                    Button {
                        vm.addSuggestedTag(suggestion.name, to: [path])
                    } label: {
                        HStack(spacing: AppSpacing.xxs) {
                            Image(systemName: "plus")
                                .font(.appIcon(8, weight: .bold))
                            Text(suggestion.name)
                                .font(.appCaption)
                        }
                        .foregroundStyle(Color.appPrimaryText)
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, AppSpacing.xxs + 1)
                        .background(Capsule(style: .continuous).fill(Color.appElevatedSurface))
                        .overlay(Capsule(style: .continuous).strokeBorder(Color.appAccent.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(AppAdaptiveButtonStyle())
                    .help(Self.help(for: suggestion))
                    .accessibilityLabel("Add tag \(suggestion.name)")
                }
            }
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.xs)
    }

    private static func help(for suggestion: TagSuggestion) -> String {
        switch suggestion.source {
        case .content: return "Add tag \"\(suggestion.name)\" (seen in the image, \(Int((suggestion.confidence * 100).rounded()))% confidence)"
        case .colour: return "Add tag \"\(suggestion.name)\" (dominant colour)"
        case .model: return "Add tag \"\(suggestion.name)\" (generation model)"
        }
    }

    // MARK: Loading

    private func load() async {
        guard isImage else { return }
        let loaded = await controller.record(for: path)
        guard !Task.isCancelled else { return }
        record = loaded
        hasLoaded = true
        guard controller.suggestTagsEnabled else {
            suggestions = []
            return
        }
        let result = await TagSuggestionController.shared.suggestions(
            for: path, record: loaded, model: vm.suggestionModel(for: path),
            existingTagNames: vm.tagsForFile(at: path).map(\.name)
        )
        guard !Task.isCancelled else { return }
        suggestions = result
    }

    private func analyzeNow() async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        let records = await controller.analyzeNow(paths: [path])
        record = records[path]
    }
}

/// "In a stack of 4 · same seed and prompt" with Expand / Collapse and Set as Cover.
private struct StackMembershipCard: View {
    @Environment(ExplorerViewModel.self) private var vm
    let path: String

    var body: some View {
        if vm.isStackingEnabled, let stack = vm.stackController.stack(containing: path) {
            let isExpanded = vm.stackController.isExpanded(stack.id)
            AnalysisDetailCard(title: "Stack") {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.appCallout)
                        .foregroundStyle(Color.appAccent)
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text("One of \(stack.count) variants")
                            .font(.appBody)
                            .foregroundStyle(Color.appPrimaryText)
                        Text(detail(for: stack))
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(isExpanded ? "Collapse" : "Expand") {
                        vm.toggleStackExpansion(stack.id)
                    }
                    .buttonStyle(AppLabeledButtonStyle(height: 22, horizontalPadding: AppSpacing.md, cornerRadius: AppRadius.sm))
                    .font(.appCaption)
                    .help(isExpanded ? "Show only the cover" : "Show every variant in the listing")
                }
            }
        }
    }

    private func detail(for stack: FileStack) -> String {
        let reasons = StackReason.allCases.filter(stack.reasons.contains).map(\.title).joined(separator: ", ")
        let cover = stack.coverPath == path ? "This is the cover" : "Cover: \((stack.coverPath as NSString).lastPathComponent)"
        return reasons.isEmpty ? cover : "\(cover) · \(reasons)"
    }
}

/// Same card treatment as the details panel's own cards.
struct AnalysisDetailCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if let title {
                Text(title)
                    .font(.appIcon(11, weight: .medium))
                    .foregroundStyle(Color.appMuted)
            }
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                content()
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface.opacity(0.6))
            .cornerRadius(AppRadius.lg)
        }
    }
}

/// Wraps chips onto as many lines as they need.
struct SuggestionChipFlow: Layout {
    var spacing: CGFloat = AppSpacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
