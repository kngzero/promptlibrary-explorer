import SwiftUI

/// Prompt Lineage: related files as a vertical chain, oldest first, each step
/// showing its thumbnail, its prompt diffed against the step before, and the
/// parameters that changed.
struct PromptLineageView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let request: PromptLineageRequest

    @State private var steps: [PromptLineageStep] = []
    @State private var isLoading = true
    @State private var showNegative = false

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Prompt Lineage",
                subtitle: "\(request.title), oldest first",
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                onClose: close
            ) {
                if steps.contains(where: { !($0.negativeDiff ?? []).isEmpty || !$0.input.negative.isEmpty }) {
                    Toggle("Negative prompts", isOn: $showNegative)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.appCaption)
                }
            }

            Group {
                if isLoading {
                    ProgressView("Reading prompts…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if steps.isEmpty {
                    FeatureEmptyState(systemImage: "text.badge.xmark", title: "No prompts found", message: "None of these files could be read.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(steps) { step in
                                stepRow(step, isLast: step.index == steps.count - 1)
                            }
                        }
                        .padding(AppSpacing.xl)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FeatureSheetFooter {
                PromptDiffLegend()
                Spacer()
                Text(summary)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
        }
        .frame(width: 780, height: 680)
        .background(Color.appBackground)
        .task {
            let inputs = await vm.loadLineageInputs(request.paths)
            steps = PromptLineageBuilder.build(inputs)
            isLoading = false
        }
    }

    private var summary: String {
        let changed = steps.filter { step in
            guard let diff = step.promptDiff else { return false }
            return diff.contains { $0.op != .equal }
        }.count
        return steps.isEmpty ? "" : "\(steps.count) steps · prompt changed in \(changed)"
    }

    // MARK: Step

    private func stepRow(_ step: PromptLineageStep, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    FeatureThumbnail(path: step.input.path, size: 76)
                    Text("\(step.index + 1)")
                        .font(.appMicro)
                        .foregroundStyle(Color.appOnAccent)
                        .padding(.horizontal, AppSpacing.xs + 1)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.appAccent))
                        .padding(AppSpacing.xs)
                        .accessibilityLabel("Step \(step.index + 1)")
                }
            }
            .frame(width: 76)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    Text(step.input.name)
                        .font(.appHeadline)
                        .foregroundStyle(Color.appPrimaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let date = step.input.date {
                        Text(dateFormatter.string(from: date))
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                    }
                    Spacer(minLength: AppSpacing.sm)
                    stepMenu(step)
                }

                if step.isFirst {
                    parameterSummary(step.input.parameters)
                } else if !step.parameterChanges.isEmpty {
                    PromptFlowLayout {
                        ForEach(step.parameterChanges, id: \.self) { change in
                            PromptChip(text: changeText(change), systemImage: "arrow.triangle.2.circlepath", tint: .appAccent)
                        }
                    }
                }

                promptBlock(step)

                if showNegative {
                    negativeBlock(step)
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.appSurface))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).strokeBorder(Color.appBorder, lineWidth: 1))
            .padding(.bottom, isLast ? 0 : AppSpacing.lg)
        }
        // Chain connector from this step's thumbnail down to the next one.
        .background(alignment: .topLeading) {
            if !isLast {
                Rectangle()
                    .fill(Color.appControlBorder)
                    .frame(width: 2)
                    .padding(.top, 76 + AppSpacing.xs)
                    .padding(.leading, 37)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func promptBlock(_ step: PromptLineageStep) -> some View {
        if let diff = step.promptDiff {
            if step.input.prompt.isEmpty && diff.isEmpty {
                noPrompt
            } else if !diff.contains(where: { $0.op != .equal }) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Prompt unchanged")
                        .font(.appCaptionEmphasis)
                        .foregroundStyle(Color.appMuted)
                    Text(step.input.prompt)
                        .font(.appCallout)
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            } else {
                let counts = PromptTokenDiff.changeCounts(diff)
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(changeCountText(counts))
                        .font(.appCaptionEmphasis)
                        .foregroundStyle(Color.appMuted)
                    PromptDiffTextView(tokens: diff)
                }
            }
        } else if step.input.prompt.isEmpty {
            noPrompt
        } else {
            Text(step.input.prompt)
                .font(.appBody)
                .foregroundStyle(Color.appPrimaryText.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func negativeBlock(_ step: PromptLineageStep) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Negative")
                .font(.appCaptionEmphasis)
                .foregroundStyle(Color.appMuted)
            if let diff = step.negativeDiff, diff.contains(where: { $0.op != .equal }) {
                PromptDiffTextView(tokens: diff, font: .appCallout)
            } else if step.input.negative.isEmpty {
                Text("None").font(.appCallout).foregroundStyle(Color.appMuted)
            } else {
                Text(step.input.negative)
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, AppSpacing.xs)
    }

    private var noPrompt: some View {
        Text("No prompt text")
            .font(.appCallout)
            .italic()
            .foregroundStyle(Color.appMuted)
    }

    private func parameterSummary(_ p: GenerationParameters) -> some View {
        let items: [String] = [
            p.model.map { "Model \($0)" },
            p.sampler.map { "Sampler \($0)" },
            p.steps.map { "Steps \($0)" },
            p.cfg.map { "CFG \($0)" },
            p.seed.map { "Seed \($0)" },
            p.width.flatMap { w in p.height.map { "\(w)×\($0)" } },
        ].compactMap { $0 }
        return PromptFlowLayout {
            ForEach(items, id: \.self) { PromptChip(text: $0) }
        }
    }

    private func stepMenu(_ step: PromptLineageStep) -> some View {
        Menu {
            Button("Copy Prompt") {
                ClipboardService.copyString(step.input.prompt)
                vm.showToast("Prompt copied", type: .success)
            }
            .disabled(step.input.prompt.isEmpty)
            Button("Open in Prompt Builder") {
                let draft = PromptDraft(prompt: step.input.prompt, negative: step.input.negative, parameters: step.input.parameters)
                var sourced = draft
                sourced.sourcePath = step.input.path
                close()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    vm.promptWorkflows.builderRequest = PromptBuilderRequest(draft: sourced, sourceName: step.input.name)
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: step.input.path)])
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.appCallout)
                .foregroundStyle(Color.appMuted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Step Actions")
        .accessibilityLabel("Step Actions")
    }

    private func changeText(_ change: PromptParamChange) -> String {
        "\(change.label) \(change.old ?? "—") → \(change.new ?? "—")"
    }

    private func changeCountText(_ counts: (added: Int, removed: Int)) -> String {
        var parts: [String] = []
        if counts.added > 0 { parts.append("+\(counts.added) word\(counts.added == 1 ? "" : "s")") }
        if counts.removed > 0 { parts.append("−\(counts.removed) word\(counts.removed == 1 ? "" : "s")") }
        return parts.isEmpty ? "Punctuation changed" : parts.joined(separator: "  ")
    }

    private func close() {
        vm.promptWorkflows.lineageRequest = nil
        dismiss()
    }
}
