import SwiftUI

/// Sidebar "Inbox": files ingested from watched folders in the last 7 days, with
/// a badge for the ones not seen yet. Only shown once a source is configured.
///
/// Rows go straight into the sidebar `List` (no modals here: the log sheet is
/// presented by `IngestSheetsHost`, per the list-group-modals rule).
struct InboxSidebarSection: View {
    @Environment(ExplorerViewModel.self) private var vm
    @AppStorage("sidebar.inbox.expanded") private var isExpanded = true
    private var controller: IngestController { .shared }

    var body: some View {
        if controller.hasSources {
            SidebarSectionHeader(
                title: "Inbox",
                isExpanded: $isExpanded,
                isCollapsed: false,
                expandedIcon: "checkmark.circle",
                collapsedIcon: "checkmark.circle",
                helpText: "Mark All Seen"
            ) {
                vm.markInboxSeen()
            }
            .listRowSeparator(.hidden)
            .selectionDisabled()
            .contextMenu { InboxMenuItems() }

            if isExpanded {
                InboxRow(
                    title: "New Files",
                    icon: "tray.and.arrow.down.fill",
                    badge: controller.unseenCount,
                    detail: controller.isBusy ? "Processing…" : nil,
                    isWarning: false,
                    isSelected: isShowing(nil)
                ) {
                    vm.activePane = .sidebar
                    vm.openInbox()
                }
                .contextMenu { InboxMenuItems() }

                ForEach(controller.sources) { source in
                    let available = controller.isAvailable(source)
                    InboxRow(
                        title: source.name,
                        icon: available ? "folder.badge.gearshape" : "exclamationmark.triangle",
                        badge: controller.unseenCount(sourceID: source.id),
                        detail: available ? (source.isEnabled ? nil : "Paused") : "Unavailable",
                        isWarning: !available,
                        isSelected: isShowing(source.id),
                        indent: true
                    ) {
                        vm.activePane = .sidebar
                        vm.openInbox(sourceID: source.id)
                    }
                    .help((source.path as NSString).abbreviatingWithTildeInPath)
                    .contextMenu {
                        Button("Process Existing Files Now") {
                            controller.processExistingNow(sourceID: source.id)
                        }
                        .disabled(!available || !source.isEnabled)
                        Divider()
                        InboxMenuItems()
                    }
                }
            }
        }
    }

    private func isShowing(_ sourceID: UUID?) -> Bool {
        guard let listing = vm.activeVirtualListing, case let .inbox(shown) = listing.kind else { return false }
        return shown == sourceID
    }
}

/// Shared by the Inbox header and rows' context menus.
private struct InboxMenuItems: View {
    @Environment(ExplorerViewModel.self) private var vm

    var body: some View {
        Button("Mark All Seen") { vm.markInboxSeen() }
            .disabled(IngestController.shared.unseenCount == 0)
        Button("Clear Inbox") { IngestController.shared.clearInbox() }
            .help("Empties the Inbox list. No files are changed.")
        Divider()
        Button("Show Ingest Log…") { vm.showIngestLog() }
        Button("Ingest Settings…") { vm.openIngestSettings() }
    }
}

private struct InboxRow: View {
    let title: String
    let icon: String
    let badge: Int
    let detail: String?
    let isWarning: Bool
    let isSelected: Bool
    var indent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon)
                    .foregroundStyle(isWarning ? Color.appError : (isSelected ? Color.appAccent : Color.appSidebarSecondaryText))
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text(title)
                    .font(badge > 0 ? .appSidebarItemEmphasis : .appSidebarItem)
                    .foregroundStyle(isSelected ? Color.appPrimaryText : Color.appSidebarText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if let detail {
                    Text(detail)
                        .font(.appSidebarDetail)
                        .foregroundStyle(isWarning ? Color.appError : Color.appSidebarSecondaryText)
                }
                if badge > 0 {
                    Text(badge > 999 ? "999+" : "\(badge)")
                        .font(.appCaptionEmphasis)
                        .monospacedDigit()
                        .foregroundStyle(Color.appOnAccent)
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.appAccent))
                }
            }
            .padding(.leading, indent ? AppSpacing.lg : 0)
            .padding(.vertical, AppSpacing.xxs)
            .padding(.horizontal, AppSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(isSelected ? Color.appSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityText: String {
        var text = title
        if badge > 0 { text += ", \(badge) new" }
        if let detail { text += ", \(detail)" }
        return text
    }
}
