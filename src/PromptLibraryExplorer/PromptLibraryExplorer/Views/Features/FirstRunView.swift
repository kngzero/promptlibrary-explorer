import SwiftUI
import UniformTypeIdentifiers

/// Shown when no root folder is open: Open Folder, recent folders, and a drop
/// target that opens a dragged-in folder.
struct FirstRunView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var isDropTargeted = false
    @State private var hoveredRecentID: String?

    private var recents: [RecentItem] {
        vm.recentFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        VStack(spacing: AppSpacing.xxl) {
            VStack(spacing: AppSpacing.lg) {
                Image(systemName: "folder.badge.plus")
                    .font(.appIcon(52))
                    .foregroundStyle(Color.appAccent)

                Text("PromptLibrary Explorer")
                    .font(.appLargeTitle)
                    .foregroundStyle(Color.appPrimaryText)

                Text("Open a folder to browse your prompt library")
                    .font(.appBody)
                    .foregroundStyle(Color.appMuted)

                // ⌘O is owned by File > Open Folder…
                Button("Open Folder…") {
                    Task { await vm.openFolder() }
                }
                .buttonStyle(AppPrimaryButtonStyle(font: .appCalloutEmphasis, horizontalPadding: AppSpacing.xl))
                .padding(.top, AppSpacing.xs)
            }

            dropZone

            if !recents.isEmpty {
                recentList
            }
        }
        .padding(AppSpacing.xxxl)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
