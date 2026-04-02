import SwiftUI
import UniformTypeIdentifiers

struct FileTreeView: View {
    @Environment(ExplorerViewModel.self) private var vm

    var body: some View {
        ScrollViewReader { proxy in
            List {
                // Favorites
                Section {
                    FavoriteItemView(name: "Desktop", icon: "desktopcomputer", favorite: .desktop)
                    FavoriteItemView(name: "Documents", icon: "doc.text", favorite: .documents)
                    FavoriteItemView(name: "Pictures", icon: "photo", favorite: .pictures)
                } header: {
                    SidebarSectionHeader(title: "Favorites")
                }

                // Smart Folders
                SmartFolderSidebarView(smartFolders: vm.smartFolders)

                // Folder Tree
                if vm.explorerRootPath != nil {
                    Section {
                        ForEach(vm.sidebarFolders) { folder in
                            SidebarFolderRow(item: folder)
                                .id(folder.id)
                        }
                    } header: {
                        SidebarSectionHeader(
                            title: "Folders",
                            isCollapsed: vm.isSidebarTreeCollapsed,
                            expandedIcon: "rectangle.compress.vertical",
                            collapsedIcon: "rectangle.expand.vertical",
                            helpText: vm.isSidebarTreeCollapsed ? "Restore Folder Expansion" : "Collapse All Folders"
                        ) {
                            vm.toggleSidebarTreeCollapse()
                        }
                    }
                }
            }
            .onAppear {
                scrollToSelection(using: proxy)
            }
            .onChange(of: vm.selectedFolderPath?.standardizedFileURL.path) { _, _ in
                scrollToSelection(using: proxy)
            }
            .onChange(of: vm.sidebarFolders) { _, _ in
                scrollToSelection(using: proxy)
            }
            .onChange(of: vm.activePane) { _, activePane in
                guard activePane == .sidebar else { return }
                scrollToSelection(using: proxy)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await vm.openFolder() }
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Open Folder")
            }
        }
    }

    private func scrollToSelection(using proxy: ScrollViewProxy) {
        guard let selectionPath = vm.selectedFolderPath?.standardizedFileURL.path else { return }
        guard vm.sidebarFolders.contains(where: { $0.id == selectionPath }) else { return }

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.16)) {
                proxy.scrollTo(selectionPath, anchor: .center)
            }
        }
    }
}

struct SidebarSectionHeader: View {
    let title: String
    var isCollapsed: Bool? = nil
    var expandedIcon: String = "chevron.down"
    var collapsedIcon: String = "chevron.right"
    var helpText: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appMuted)

            Spacer(minLength: 0)

            if let action, let isCollapsed {
                Button(action: action) {
                    Image(systemName: isCollapsed ? collapsedIcon : expandedIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.appMuted)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.appSurface.opacity(0.7))
                        )
                }
                .buttonStyle(.plain)
                .help(helpText ?? "")
            }
        }
        .padding(.vertical, 5)
        .textCase(nil)
    }
}

// MARK: - Favorite Item

struct FavoriteItemView: View {
    @Environment(ExplorerViewModel.self) private var vm
    let name: String
    let icon: String
    let favorite: FavoriteFolder

    var body: some View {
        Button {
            vm.activePane = .sidebar
            Task { await vm.selectFavorite(favorite) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 18)

                Text(name)

                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

// MARK: - Sidebar Folder Row

struct SidebarFolderRow: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: SidebarFolderItem

    @State private var isDropTarget = false

    private var isSelected: Bool {
        vm.selectedFolderPath == item.url
    }

    private var isActiveSelection: Bool {
        isSelected && vm.activePane == .sidebar
    }

    var body: some View {
        folderRow
    }

    private var folderRow: some View {
        HStack(spacing: 8) {
            Group {
                if item.hasChildren {
                    Button {
                        vm.activePane = .sidebar
                        vm.toggleSidebarFolderExpansion(for: item.url)
                    } label: {
                        Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.appPrimaryText.opacity(0.9) : Color.appMuted)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                        .frame(width: 14, height: 14)
                }
            }

            Image(systemName: "folder.fill")
                .foregroundStyle(isSelected ? Color.appAccent : Color.appMuted)
                .font(.system(size: 14))

            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(item.depth) * 14)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.appSelected : (isDropTarget ? Color.appAccent.opacity(0.1) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActiveSelection ? Color.appAccent : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            vm.activePane = .sidebar
            Task { await vm.selectFolder(item.url) }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
            Task {
                let urls = await URLDropLoader.loadURLs(from: providers)
                guard !urls.isEmpty else { return }

                let internalPaths = Set(vm.processedFolderContents.map(\.path))
                let isInternalDrag = urls.allSatisfy { internalPaths.contains($0.standardizedFileURL.path) }

                if isInternalDrag {
                    await vm.moveDraggedItems(urls, to: item.url)
                } else {
                    await vm.importExternalFiles(urls, to: item.url)
                }
            }
            return true
        }
    }
}
