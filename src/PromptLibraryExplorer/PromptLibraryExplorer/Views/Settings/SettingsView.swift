import SwiftUI

/// Settings as a modal sheet with a sidebar + page layout, so sections can be
/// added without the page growing unreadably long.
///
/// The split is a plain `HStack` rather than a `NavigationSplitView`: the
/// settings sidebar is a fixed-width index that should never auto-collapse or
/// slide under the sheet's top edge as the layout narrows.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selection: SettingsPage = .appearance

    private let sidebarWidth: CGFloat = 210

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar

                Rectangle()
                    .fill(Color.appBorder)
                    .frame(width: 1)

                SettingsPageScaffold(page: selection) {
                    page(for: selection)
                }
                // Page state is per-page, so rebuild cleanly when the selection changes.
                .id(selection)
            }

            footer
        }
        .frame(width: 940, height: 700)
        .background(Color.appBackground)
        .onExitCommand { dismiss() }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                ForEach(SettingsPageGroup.allCases) { group in
                    Text(group.title.uppercased())
                        .font(.appIcon(10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Color.appMuted)
                        .padding(.horizontal, 10)
                        .padding(.top, group == SettingsPageGroup.allCases.first ? 0 : 14)
                        .padding(.bottom, AppSpacing.xs)
                        .accessibilityLabel(group.title)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(group.pages) { page in
                        SettingsSidebarRow(
                            page: page,
                            isSelected: page == selection
                        ) {
                            selection = page
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 14)
        }
        .frame(width: sidebarWidth)
        .background(Color.appSidebarBackground)
    }

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)

            // Carries Escape. A real button holds the shortcut wherever focus
            // sits, where `.onExitCommand` stops firing once a control inside
            // the sheet takes focus.
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.appBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.appBorder)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func page(for selection: SettingsPage) -> some View {
        switch selection {
        case .appearance:
            AppearanceSettingsPage()
        case .filters:
            FiltersSettingsPage()
        case .fileOperations:
            FileOperationsSettingsPage()
        case .libraryIndex:
            LibraryIndexSettingsPage()
        case .organize:
            OrganizeSettingsPage()
        case .storage:
            StorageSettingsPage()
        }
    }
}

private struct SettingsSidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: page.icon)
                    .font(.appCalloutEmphasis)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 16)
                    .accessibilityHidden(true)

                Text(page.title)
                    .font(.appIcon(13, weight: .medium))
                    .foregroundStyle(Color.appPrimaryText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(rowFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowFill: Color {
        if isSelected {
            return Color.appSelected
        }
        return isHovering ? Color.appHover : Color.clear
    }
}
