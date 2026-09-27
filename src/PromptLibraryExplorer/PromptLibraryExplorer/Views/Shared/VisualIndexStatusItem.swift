import SwiftUI

/// Bottom status-bar item for background indexing: the visual index (similar images,
/// colour search) and the text library index, combined into one compact indicator.
/// Hidden when neither is running or paused. Click → popover with each pipeline's
/// progress and the visual pipeline's Pause / Resume / Stop.
struct VisualIndexStatusItem: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var showsPopover = false

    private var controller: VisualIndexController { .shared }

    private var visualActive: Bool { controller.state == .indexing || controller.state == .paused }
    private var isVisible: Bool { vm.isLibraryIndexing || visualActive || ingestActive || showsPopover || GeoTimelineController.shared.isBackfilling }
    /// Ingest inbox processing new files (its row in the popover).
    private var ingestActive: Bool { IngestController.shared.isBusy }

    var body: some View {
        if isVisible {
            Button {
                showsPopover.toggle()
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    indicator
                    Text(summary)
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.horizontal, AppSpacing.sm)
                .frame(height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(AppAdaptiveButtonStyle())
            .help(helpText)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Shows indexing progress and controls")
            .popover(isPresented: $showsPopover, arrowEdge: .top) {
                IndexingStatusPopover(onOpenSettings: { showsPopover = false })
                    .environment(vm)
            }
        }
    }

    // MARK: Compact label

    /// Both pipelines' counts summed.
    private var combined: (done: Int, total: Int)? {
        var done = 0, total = 0
        if vm.isLibraryIndexing, let p = vm.libraryIndexProgress { done += p.done; total += p.total }
        if visualActive, let p = controller.progress { done += p.done; total += p.total }
        return total > 0 ? (done, total) : nil
    }

    private var onlyPaused: Bool { controller.state == .paused && !vm.isLibraryIndexing }

    private var summary: String {
        if ingestActive, !vm.isLibraryIndexing, !visualActive {
            let ingest = IngestController.shared
            return "Ingesting \((ingest.processingCount + ingest.waitingCount).formatted())…"
        }
        if onlyPaused { return "Indexing paused" }
        guard let combined else { return "Indexing…" }
        return "Indexing \(combined.done.formatted()) / \(combined.total.formatted())"
    }

    @ViewBuilder
    private var indicator: some View {
        if onlyPaused {
            Image(systemName: "pause.circle")
                .font(.appIcon(11, weight: .medium))
                .foregroundStyle(Color.appMuted)
        } else if let combined {
            ProgressRing(fraction: Double(combined.done) / Double(max(1, combined.total)))
                .frame(width: 11, height: 11)
        } else {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 11, height: 11)
        }
    }

    private var helpText: String {
        var parts: [String] = []
        if vm.isLibraryIndexing { parts.append("Indexing prompts for library search") }
        switch controller.state {
        case .indexing: parts.append("Indexing images for visual search")
        case .paused: parts.append("Visual indexing paused")
        default: break
        }
        return parts.isEmpty ? "Indexing status" : parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        if let combined, !onlyPaused {
            return "Indexing, \(combined.done) of \(combined.total) files"
        }
        return onlyPaused ? "Visual indexing paused" : "Indexing"
    }
}

/// Small determinate ring in the accent colour.
private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.appBorder, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(Color.appAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Popover

private struct IndexingStatusPopover: View {
    @Environment(ExplorerViewModel.self) private var vm
    let onOpenSettings: () -> Void

    private var controller: VisualIndexController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            section(
                title: "Library Search",
                icon: "text.magnifyingglass",
                status: vm.isLibraryIndexing ? "Indexing prompts…" : "Up to date",
                progress: vm.isLibraryIndexing ? (vm.libraryIndexProgress ?? (0, 0)) : nil,
                currentItem: nil
            )

            Divider()

            section(
                title: "Visual Search",
                icon: "photo.stack",
                status: visualStatus,
                progress: controller.state == .indexing || controller.state == .paused ? (controller.progress ?? (0, 0)) : nil,
                currentItem: controller.state == .indexing ? controller.currentItemName : nil
            )

            visualControls

            IngestStatusSection()

            // Capture dates / locations of already-indexed files (Views/Timeline).
            CaptureDateStatusSection()

            Divider()

            HStack {
                Spacer(minLength: 0)
                Button("Open Settings…") {
                    onOpenSettings()
                    // Land on Search Index (where the indexing controls live).
                    UserDefaults.standard.set(SettingsPage.libraryIndex.rawValue, forKey: SettingsView.selectedPageKey)
                    NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                }
                .buttonStyle(AppLabeledButtonStyle(height: 24))
                .font(.appCallout)
                .help("Open Settings ▸ Search Index")
                .accessibilityHint("Opens Settings, where the Search Index page has every indexing control")
            }
        }
        .padding(AppSpacing.xl)
        .frame(width: 300)
        .background(Color.appBackground)
    }

    private var visualStatus: String {
        switch controller.state {
        case .idle: return "Waiting to start"
        case .indexing: return "Indexing images and videos…"
        case .paused: return "Paused"
        case .stopped: return "Stopped — automatic indexing is off"
        case .completed: return "Up to date"
        }
    }

    @ViewBuilder
    private var visualControls: some View {
        HStack(spacing: AppSpacing.md) {
            switch controller.state {
            case .indexing:
                controlButton("Pause", icon: "pause.fill", hint: "Pauses visual indexing; finished files are kept") {
                    controller.pause()
                }
            case .paused:
                controlButton("Resume", icon: "play.fill", hint: "Continues visual indexing where it stopped") {
                    controller.resume()
                }
            case .stopped:
                controlButton("Turn On", icon: "play.fill", hint: "Re-enables automatic visual indexing") {
                    controller.isEnabled = true
                    if let root = vm.explorerRootPath { controller.start(root: root) }
                }
            case .idle, .completed:
                EmptyView()
            }
            if controller.state == .indexing || controller.state == .paused {
                controlButton("Stop", icon: "stop.fill", hint: "Stops visual indexing and turns off automatic indexing until you turn it back on") {
                    controller.stop()
                }
            }
        }
    }

    private func controlButton(_ title: String, icon: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.appCallout)
        }
        .buttonStyle(AppLabeledButtonStyle(height: 24))
        .help(hint)
        .accessibilityLabel("\(title) visual indexing")
        .accessibilityHint(hint)
    }

    @ViewBuilder
    private func section(
        title: String,
        icon: String,
        status: String,
        progress: (done: Int, total: Int)?,
        currentItem: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: icon)
                    .font(.appIcon(12, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.appHeadline)
                    .foregroundStyle(Color.appPrimaryText)
                Spacer(minLength: 0)
                if let progress, progress.total > 0 {
                    Text("\(progress.done.formatted()) / \(progress.total.formatted())")
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                        .monospacedDigit()
                }
            }
            Text(status)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
            if let progress {
                if progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .tint(Color.appAccent)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.appAccent)
                }
            }
            if let currentItem {
                Text(currentItem)
                    .font(.appFootnote)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(currentItem)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(title: title, status: status, progress: progress))
    }

    private func accessibilitySummary(title: String, status: String, progress: (done: Int, total: Int)?) -> String {
        guard let progress, progress.total > 0 else { return "\(title): \(status)" }
        return "\(title): \(status), \(progress.done) of \(progress.total) files"
    }
}

// MARK: - Ingest row

/// The ingest inbox's line in the indexing popover (only with a watched folder).
private struct IngestStatusSection: View {
    private var controller: IngestController { .shared }

    var body: some View {
        if controller.hasSources {
            Divider()
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.appIcon(12, weight: .medium))
                        .foregroundStyle(Color.appAccent)
                        .accessibilityHidden(true)
                    Text("Ingest Inbox")
                        .font(.appHeadline)
                        .foregroundStyle(Color.appPrimaryText)
                    Spacer(minLength: 0)
                    Button("Show Log…") { controller.logSheetOpen = true }
                        .buttonStyle(AppLabeledButtonStyle(height: 22))
                        .font(.appCaption)
                        .help("Show the last 200 ingest events")
                }
                Text(status)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                if controller.isBusy {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.appAccent)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Ingest Inbox: \(status)")
        }
    }

    private var status: String {
        if controller.processingCount > 0 {
            return "Processing \(controller.processingCount) new file\(controller.processingCount == 1 ? "" : "s")…"
        }
        if controller.waitingCount > 0 {
            return "Waiting for \(controller.waitingCount) file\(controller.waitingCount == 1 ? "" : "s") to finish writing"
        }
        let active = controller.sources.filter { $0.isEnabled && controller.isAvailable($0) }.count
        let unavailable = controller.unavailableSourceIDs.count
        var text = "Watching \(active) folder\(active == 1 ? "" : "s")"
        if unavailable > 0 { text += " · \(unavailable) unavailable" }
        return text
    }
}
