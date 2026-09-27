import SwiftUI
import UniformTypeIdentifiers

/// Shown when no root folder is open: Open Folder, the welcome tour, three
/// suggested starting actions, recent folders, and a drop target that opens a
/// dragged-in folder.
struct FirstRunView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var isDropTargeted = false
    @State private var hoveredRecentID: String?

    private var recents: [RecentItem] {
        vm.recentFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.appBackground)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            Task {
                let urls = await URLDropLoader.loadURLs(from: providers)
                let folders = urls.filter { url in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                }
                guard let folder = folders.first else {
                    vm.showToast("Drop a folder to open it", type: .info)
                    return
                }
                await vm.openExternalURLs([folder])
            }
            return true
        }
    }

    private var content: some View {
        VStack(spacing: AppSpacing.xxl) {
            VStack(spacing: AppSpacing.lg) {
                Image(systemName: "folder.badge.plus")
                    .font(.appIcon(52))
                    .foregroundStyle(Color.appAccent)

                Text("PromptLibrary Explorer")
                    .font(.appLargeTitle)
                    .foregroundStyle(Color.appPrimaryText)

                Text("A prompt-aware library for your AI images, video and audio")
                    .font(.appBody)
                    .foregroundStyle(Color.appMuted)
                    .multilineTextAlignment(.center)

                // ⌘O is owned by File > Open Folder…
                Button("Open Folder…") {
                    Task { await vm.openFolder() }
                }
                .buttonStyle(AppPrimaryButtonStyle(font: .appCalloutEmphasis, horizontalPadding: AppSpacing.xl))
                .padding(.top, AppSpacing.xs)

                Button {
                    vm.presentWelcomeTour()
                } label: {
                    Label("New here? Take the one-minute tour", systemImage: "sparkles")
                        .font(.appCallout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appAccentHover)
                .help("A short tour of the app (Help ▸ Welcome Tour…)")
            }

            startingActions

            dropZone

            if !recents.isEmpty {
                recentList
            }
        }
        .padding(AppSpacing.xxxl)
        .frame(maxWidth: 600)
    }

    /// Three suggested ways to start.
    private var startingActions: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            FirstRunActionCard(
                symbol: "tray.and.arrow.down",
                title: "Watch a render folder",
                detail: "New files from ComfyUI or Downloads arrive in the Inbox, renamed and tagged.",
                isPrimary: true
            ) { vm.perform(.watchedFolders) }

            FirstRunActionCard(
                symbol: "arrow.triangle.2.circlepath",
                title: "Bring your ratings",
                detail: "Import curation data or restore a backup from another Mac in Settings ▸ Data."
            ) { vm.perform(.dataSettings) }

            FirstRunActionCard(
                symbol: "questionmark.circle",
                title: "Explore features",
                detail: "Search every feature in Help, with a Show Me for each."
            ) { vm.openHelp() }
        }
    }

    private var dropZone: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.appIcon(22))
                .foregroundStyle(isDropTargeted ? Color.appAccent : Color.appMuted)
            Text(isDropTargeted ? "Release to open this folder" : "…or drag a folder here")
                .font(.appCallout)
                .foregroundStyle(isDropTargeted ? Color.appPrimaryText : Color.appMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xl)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(isDropTargeted ? Color.appSelected : Color.appSurface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.appAccent : Color.appControlBorder,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("Recent Folders")
                    .font(.appCaptionEmphasis)
                    .foregroundStyle(Color.appMuted)
                Spacer()
                Button("Clear") { vm.clearRecentFolders() }
                    .buttonStyle(AppLabeledButtonStyle(height: 20, horizontalPadding: AppSpacing.sm, showsRestingChrome: false))
                    .font(.appCaption)
            }

            VStack(spacing: AppSpacing.xxs) {
                ForEach(recents.prefix(8)) { item in
                    Button {
                        Task { await vm.openRecentFolder(item) }
                    } label: {
                        HStack(spacing: AppSpacing.md) {
                            Image(systemName: "folder.fill")
                                .font(.appCallout)
                                .foregroundStyle(Color.appAccent)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.name)
                                    .font(.appCalloutEmphasis)
                                    .foregroundStyle(Color.appPrimaryText)
                                    .lineLimit(1)
                                Text((item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                    .font(.appFootnote)
                                    .foregroundStyle(Color.appMuted)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            Spacer(minLength: AppSpacing.md)
                            Text(item.timestamp.formatted(.relative(presentation: .named)))
                                .font(.appFootnote)
                                .foregroundStyle(Color.appMuted)
                        }
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm)
                        .background(FeatureRowBackground(isSelected: false, isHovered: hoveredRecentID == item.id))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { hoveredRecentID = item.id } else if hoveredRecentID == item.id { hoveredRecentID = nil }
                    }
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        }
                        Button("Remove from Recents") { vm.removeRecentFolder(item) }
                    }
                }
            }
        }
    }
}

/// One suggested starting action on the first-run screen.
private struct FirstRunActionCard: View {
    let symbol: String
    let title: String
    let detail: String
    var isPrimary = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Image(systemName: symbol)
                    .font(.appIcon(18, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.appCalloutEmphasis)
                    .foregroundStyle(Color.appPrimaryText)
                Text(detail)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(isHovered ? Color.appHover : Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(isPrimary ? Color.appAccent.opacity(0.45) : Color.appBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
