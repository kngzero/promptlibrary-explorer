import SwiftUI

struct SmartFolderSidebarView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @AppStorage("sidebar.smartFolders.expanded") private var isExpanded = true
    let smartFolders: [SmartFolder]
    @State private var pendingDelete: SmartFolder?

    var body: some View {
        if !smartFolders.isEmpty {
            // Header is an inline row (not the Section `header:` slot) so macOS
            // doesn't attach its native hover-reveal section-collapse chevron or
            // the large inter-section gaps. The leading chevron and the "+" are
            // static content (not Buttons) so they stay visible by default.
            Group {
                header
                    .sidebarSectionStart()
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    // Modals live on this single row. On the Group they'd be applied
                    // to EVERY row of the section inside the List, so each row
                    // presented its own copy (the "sheet opens 3 times" bug).
                    .alert(
                        "Delete \"\(pendingDelete?.name ?? "")\"?",
                        isPresented: Binding(
                            get: { pendingDelete != nil },
                            set: { if !$0 { pendingDelete = nil } }
                        ),
                        presenting: pendingDelete
                    ) { folder in
                        Button("Delete", role: .destructive) {
                            vm.deleteSmartFolder(folder)
                            pendingDelete = nil
                        }
                        Button("Cancel", role: .cancel) { pendingDelete = nil }
                    } message: { _ in
                        Text("The smart folder and its rules are removed. Your files are not touched. This can't be undone.")
                    }

                if isExpanded {
                    ForEach(smartFolders) { folder in
                        smartFolderRow(folder)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.appIcon(10, weight: .bold))
                    .foregroundStyle(Color.appSidebarSecondaryText)
                    .frame(width: 12)

                Text("Smart Folders")
                    .font(.appSidebarHeader)
                    .foregroundStyle(Color.appSidebarHeaderText)
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Smart Folders")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits([.isButton, .isHeader])
            .accessibilityAction { isExpanded.toggle() }

            Spacer(minLength: 0)

            Image(systemName: "plus.circle")
                .font(.appIcon(10, weight: .semibold))
                .foregroundStyle(Color.appSidebarSecondaryText)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.sm)
                        .fill(Color.appSurface.opacity(0.7))
                )
                .contentShape(Rectangle())
                .onTapGesture { vm.showSmartFolderEditor = true }
                .help("New Smart Folder")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("New Smart Folder")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { vm.showSmartFolderEditor = true }
        }
        .padding(.vertical, 5)
        // The whole row (not just the title) toggles the section; nested
        // controls keep their own taps because child gestures take priority.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
        .textCase(nil)
    }

    private func smartFolderRow(_ folder: SmartFolder) -> some View {
        Button {
            vm.activateSmartFolder(folder)
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(vm.activeSmartFolder?.id == folder.id ? Color.appAccent : Color.appSidebarSecondaryText)
                    .font(.appBody)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text(folder.name)
                    .font(.appSidebarItem)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(vm.activeSmartFolder?.id == folder.id ? Color.appPrimaryText : Color.appSidebarText)

                Spacer(minLength: 0)

                Text(criteriaLabel(folder.criteria))
                    .font(.appIcon(9))
                    .foregroundStyle(Color.appSidebarSecondaryText.opacity(0.6))
            }
            // Plain buttons only hit-test drawn content; span the column.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Smart folder \(folder.name)")
        .accessibilityValue(criteriaLabel(folder.criteria))
        .accessibilityAddTraits(vm.activeSmartFolder?.id == folder.id ? .isSelected : [])
        .accessibilityAction(named: "Edit") { vm.editSmartFolder(folder) }
        .accessibilityAction(named: "Delete") { pendingDelete = folder }
        .padding(.vertical, AppSpacing.xxs)
        .padding(.horizontal, AppSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .fill(vm.activeSmartFolder?.id == folder.id ? Color.appSelected : Color.clear)
        )
        .contextMenu {
            Button("Edit") {
                vm.editSmartFolder(folder)
            }
            Button("Delete…", role: .destructive) {
                pendingDelete = folder
            }
        }
    }

    private func criteriaLabel(_ criteria: SmartFolderCriteria) -> String {
        var parts: [String] = []
        if !criteria.searchQuery.isEmpty { parts.append("\"\(criteria.searchQuery)\"") }
        if !criteria.fileTypes.isEmpty { parts.append("\(criteria.fileTypes.count) types") }
        if criteria.minRating > 0 { parts.append("\(criteria.minRating)+\u{2605}") }
        if criteria.dateRange != .any { parts.append(criteria.dateRange.displayName) }
        if !criteria.tagIDs.isEmpty { parts.append(criteria.tagIDs.count == 1 ? "1 tag" : "\(criteria.tagIDs.count) tags") }
        if criteria.favoritesOnly { parts.append("\u{2665}") }
        let model = criteria.modelContains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { parts.append(model) }
        if criteria.requiresPrompt { parts.append("prompt") }
        if criteria.requiresNegativePrompt { parts.append("neg") }
        if parts.count > 1, criteria.matchMode == .any { return "any: " + parts.joined(separator: " \u{00B7} ") }
        return parts.joined(separator: " \u{00B7} ")
    }
}
