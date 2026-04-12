import SwiftUI

/// A Cmd+K command palette overlay for quick filtering, navigation, and actions.
struct CommandPaletteView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var isFocused: Bool

    private var results: [CommandPaletteItem] {
        let q = query.lowercased()
        var items: [CommandPaletteItem] = []

        // Folders
        for folder in vm.sidebarFolders where q.isEmpty || folder.name.lowercased().contains(q) {
            items.append(.folder(folder))
        }

        // Smart Folders
        for sf in vm.smartFolders where q.isEmpty || sf.name.lowercased().contains(q) {
            items.append(.smartFolder(sf))
        }

        // Tags
        for tag in vm.allTags where q.isEmpty || tag.name.lowercased().contains(q) {
            items.append(.tag(tag))
        }

        // Actions
        let actions: [(String, String, () -> Void)] = [
            ("Open Folder...", "folder.badge.plus", { Task { await vm.openFolder() } }),
            ("Refresh", "arrow.clockwise", { Task { await vm.refreshFolder() } }),
            ("Toggle Status Bar", "rectangle.bottomthird.inset.filled", { vm.showStatusBar.toggle(); vm.persistStatusBarVisibility() }),
            ("Toggle Preview Pane", "sidebar.right", { vm.togglePreviewPane() }),
            ("New Smart Folder", "folder.badge.gearshape", { vm.editingSmartFolder = nil; vm.showSmartFolderEditor = true }),
            ("Settings", "gearshape", { vm.settingsOpen = true }),
            ("Statistics", "chart.bar", { vm.statisticsOpen = true }),
        ]

        for (name, icon, action) in actions where q.isEmpty || name.lowercased().contains(q) {
            items.append(.action(name: name, icon: icon, action: action))
        }

        // Sort options
        let sortOptions: [(String, SortConfig)] = [
            ("Sort by Type (A-Z)", SortConfig(field: .type, direction: .asc)),
            ("Sort by Name (A-Z)", SortConfig(field: .name, direction: .asc)),
            ("Sort by Rating", SortConfig(field: .rating, direction: .asc)),
        ]

        for (name, config) in sortOptions where q.isEmpty || name.lowercased().contains(q) {
            items.append(.action(name: name, icon: "arrow.up.arrow.down") {
                vm.sortConfig = config
                vm.persistSortConfig()
            })
        }

        return Array(items.prefix(20))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.appMuted)
                TextField("Search folders, tags, actions...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.appPrimaryText)
                    .focused($isFocused)

                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.appMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.appSurface)
                    .cornerRadius(4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.appSurface.opacity(0.8))

            Divider().background(Color.appBorder)

            // Results
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                        CommandPaletteRow(item: item) {
                            handleSelection(item)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 480)
        .background(Color.appBackground.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.appAccent.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: Color.appShadowColor.opacity(0.8), radius: 24, y: 8)
        .onAppear { isFocused = true }
        .onExitCommand { vm.commandPaletteOpen = false }
    }

    private func handleSelection(_ item: CommandPaletteItem) {
        vm.commandPaletteOpen = false

        switch item {
        case .folder(let folder):
            Task { await vm.selectFolder(folder.url) }
        case .smartFolder(let sf):
            vm.activateSmartFolder(sf)
        case .tag(let tag):
            vm.filterByTagID = vm.filterByTagID == tag.id ? nil : tag.id
        case .action(_, _, let action):
            action()
        }
    }
}

enum CommandPaletteItem {
    case folder(SidebarFolderItem)
    case smartFolder(SmartFolder)
    case tag(FileTag)
    case action(name: String, icon: String, action: () -> Void)

    var displayName: String {
        switch self {
        case .folder(let f): return f.name
        case .smartFolder(let sf): return sf.name
        case .tag(let t): return t.name
        case .action(let name, _, _): return name
        }
    }
}

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                    .frame(width: 20)

                Text(item.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(1)

                Spacer()

                categoryLabel
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // SwiftUI handles hover state
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item {
        case .folder:
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.appAccent)
        case .smartFolder:
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 13))
                .foregroundStyle(Color.appAccent)
        case .tag(let tag):
            Circle()
                .fill(tag.color)
                .frame(width: 12, height: 12)
        case .action(_, let iconName, _):
            Image(systemName: iconName)
                .font(.system(size: 13))
                .foregroundStyle(Color.appMuted)
        }
    }

    @ViewBuilder
    private var categoryLabel: some View {
        let label: String = {
            switch item {
            case .folder: return "Folder"
            case .smartFolder: return "Smart Folder"
            case .tag: return "Tag"
            case .action: return "Action"
            }
        }()

        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.appMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.appSurface)
            .cornerRadius(4)
    }
}
