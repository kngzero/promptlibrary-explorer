import SwiftUI

/// Settings ▸ Search Index: text recognition and tag suggestions. Follows the visual
/// index's schedule (its Pause / Stop apply here too).
struct ImageAnalysisSettingsSection: View {
    @Environment(ExplorerViewModel.self) private var vm

    @State private var stats: (analyzed: Int, withText: Int, total: Int?)?
    @State private var confirmReset = false
    @State private var isResetting = false
    @State private var resultMessage: String?

    private var controller: ImageTextController { .shared }
    private var root: URL? { vm.explorerRootPath }

    var body: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                Label("Text in Images & Suggested Tags", systemImage: "text.viewfinder")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appAccent)
                Spacer(minLength: 0)
                Button {
                    Task { await refreshStats() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.appCalloutEmphasis)
                }
                .buttonStyle(AppIconButtonStyle(width: 24, height: 24, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                .help("Refresh image analysis statistics")
                .accessibilityLabel("Refresh image analysis statistics")
            }

            VStack(spacing: AppSpacing.md) {
                SettingsStatRow(label: "Status", detail: statusDetail, value: statusLabel)
                SettingsStatRow(label: "Analysed images", detail: "under the current root", value: analysedLabel)
                SettingsStatRow(label: "Images with text", detail: "searchable as Text in Image", value: stats.map { $0.withText.formatted() } ?? "—")
            }

            if controller.state == .analyzing, let progress = controller.progress, progress.total > 0 {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .tint(Color.appAccent)
                    HStack(spacing: AppSpacing.md) {
                        Text("\(progress.done.formatted()) of \(progress.total.formatted()) images")
                            .monospacedDigit()
                        if let name = controller.currentItemName {
                            Text(name).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Image analysis progress")
            }

            SettingsToggleRow(
                title: "Recognise text in images",
                detail: "Vision reads visible text (accurate mode, language correction on). Search it with the Text in Image search mode, All, Find in Library… and the smart-folder rule.",
                isOn: Binding(get: { controller.recognizeTextEnabled }, set: { controller.recognizeTextEnabled = $0 })
            )
            SettingsToggleRow(
                title: "Suggest tags",
                detail: "Vision classifies each image; confident, specific labels plus the colour family and model name appear as suggestions in the details panel. Suggestions are never applied on their own.",
                isOn: Binding(get: { controller.suggestTagsEnabled }, set: { controller.suggestTagsEnabled = $0 })
            )

            SettingsFootnote("Runs after the visual index, at low priority, on a reduced-size copy of each image. Pausing or stopping the visual index pauses or stops this too. Results stay on this Mac; your files are never modified.")

            HStack(spacing: AppSpacing.lg) {
                SettingsFilledButton(
                    title: "Re-analyse",
                    isEnabled: root != nil && !isResetting && controller.state != .analyzing,
                    action: { if let root { controller.reanalyze(root: root) } }
                )
                .accessibilityHint("Recognises text and classifies every image under the current library root again")

                SettingsFilledButton(
                    title: "Reset",
                    tint: Color.appError,
                    isBusy: isResetting,
                    isEnabled: !isResetting,
                    action: { confirmReset = true }
                )
                .accessibilityHint("Deletes all recognised text and suggestions")
            }
        }
        .task { await refreshStats() }
        .onChange(of: controller.state) { _, state in
            if state != .analyzing { Task { await refreshStats() } }
        }
        .alert("Reset text in images and suggestions?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                Task { await reset() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All recognised text and stored suggestions are removed for all libraries. Tags you added stay. Your files are untouched.")
        }

        if let resultMessage {
            SettingsResultBanner(message: resultMessage, tone: .success)
        }
    }

    private var statusLabel: String {
        switch controller.state {
        case .idle: return "Waiting"
        case .waiting: return "After visual index"
        case .analyzing: return "Analysing"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .completed: return "Up to date"
        }
    }

    private var statusDetail: String {
        switch controller.state {
        case .idle: return "starts after the visual index"
        case .waiting: return "starts when visual indexing finishes"
        case .analyzing: return "running in the background"
        case .paused: return "the visual index is paused"
        case .stopped:
            return controller.options.isEmpty ? "both analyses are off" : "the visual index is stopped"
        case .completed: return "new and changed images are picked up"
        }
    }

    private var analysedLabel: String {
        guard let stats else { return "—" }
        if let total = stats.total, total > 0 { return "\(stats.analyzed.formatted()) / \(total.formatted())" }
        return stats.analyzed.formatted()
    }

    private func refreshStats() async {
        stats = await ImageTextService.shared.stats(under: root)
    }

    private func reset() async {
        isResetting = true
        defer { isResetting = false }
        await controller.resetStore()
        await refreshStats()
        resultMessage = "Text in images and suggestions cleared. They rebuild after the next visual index pass, or choose Re-analyse."
    }
}
