import SwiftUI

struct SmartFolderSidebarView: View {
    @Environment(ExplorerViewModel.self) private var vm
    let smartFolders: [SmartFolder]

    var body: some View {
        if !smartFolders.isEmpty {
            Section {
                ForEach(smartFolders) { folder in
                    smartFolderRow(folder)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Smart Folders")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.appMuted)

                    Spacer(minLength: 0)

                    Button {
                        vm.showSmartFolderEditor = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.appMuted)
                            .frame(width: 18, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.appSurface.opacity(0.7))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("New Smart Folder")
                }
                .padding(.vertical, 5)
                .textCase(nil)
            }
        }
    }

    private func smartFolderRow(_ folder: SmartFolder) -> some View {
        Button {
            vm.activateSmartFolder(folder)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(vm.activeSmartFolder?.id == folder.id ? Color.appAccent : Color.appMuted)
                    .font(.system(size: 13))
                    .frame(width: 18)

                Text(folder.name)
                    .font(.appCaption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(vm.activeSmartFolder?.id == folder.id ? Color.appPrimaryText : Color.appMuted)

                Spacer(minLength: 0)

                Text(criteriaLabel(folder.criteria))
                    .font(.system(size: 9))
                    .foregroundStyle(Color.appMuted.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(vm.activeSmartFolder?.id == folder.id ? Color.appSelected : Color.clear)
        )
        .contextMenu {
            Button("Edit") {
                vm.editSmartFolder(folder)
            }
            Button("Delete", role: .destructive) {
                vm.deleteSmartFolder(folder)
            }
        }
    }

    private func criteriaLabel(_ criteria: SmartFolderCriteria) -> String {
        var parts: [String] = []
        if !criteria.searchQuery.isEmpty { parts.append("\"\(criteria.searchQuery)\"") }
        if !criteria.fileTypes.isEmpty { parts.append("\(criteria.fileTypes.count) types") }
        if criteria.minRating > 0 { parts.append("\(criteria.minRating)+\u{2605}") }
        if criteria.dateRange != .any { parts.append(criteria.dateRange.displayName) }
        return parts.joined(separator: " \u{00B7} ")
    }
}
