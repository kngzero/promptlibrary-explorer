import SwiftUI

/// The app's Settings window (the `Settings` scene, ⌘,) with a sidebar + page
/// layout, so sections can be added without the page growing unreadably long.
///
/// The split is a plain `HStack` rather than a `NavigationSplitView`: the
/// settings sidebar is a fixed-width index that should never auto-collapse,
/// slide under the titlebar, or zero out the page header as the window narrows.
struct SettingsView: View {
    /// Persisted, so the window reopens on the last page, and so other views can
    /// deep-link a page by writing `SettingsView.selectedPageKey` before opening.
    @AppStorage(SettingsView.selectedPageKey) private var selection: SettingsPage = .appearance

    static let selectedPageKey = "settings.selectedPage"

    private let sidebarWidth: CGFloat = 210

    static let defaultSize = CGSize(width: 940, height: 700)
    /// Keeps the sidebar plus a readable page on screen.
    static let minimumSize = CGSize(width: 720, height: 480)

    var body: some View {
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
        .frame(
            minWidth: Self.minimumSize.width, idealWidth: Self.defaultSize.width, maxWidth: .infinity,
            minHeight: Self.minimumSize.height, idealHeight: Self.defaultSize.height, maxHeight: .infinity
        )
        .background(Color.appBackground)
        .background(alignment: .topLeading) { closeOnEscapeButton }
        .background(SettingsWindowConfigurator(defaultSize: Self.defaultSize, minimumSize: Self.minimumSize))
    }

    /// Carries Escape. A real button holds the shortcut wherever focus sits
    /// (`.onExitCommand` stops firing once a control takes focus). ⌘W comes
    /// from the standard File ▸ Close item.
    private var closeOnEscapeButton: some View {
        Button("Close Settings") {
            NSApp.keyWindow?.performClose(nil)
        }
        .keyboardShortcut(.cancelAction)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
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

    @ViewBuilder
    private func page(for selection: SettingsPage) -> some View {
        switch selection {
        case .appearance:
            AppearanceSettingsPage()
        case .filters:
            FiltersSettingsPage()
        case .fileOperations:
            FileOperationsSettingsPage()
        case .export:
            ExportSettingsPage()
        case .libraryIndex:
            LibraryIndexSettingsPage()
        case .organize:
            OrganizeSettingsPage()
        case .data:
            DataSettingsPage()
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

/// Gives the Settings window a remembered, resizable frame. The `Settings`
/// scene opens its window at the content's fitting size and doesn't restore
/// frames, so this sets the default size once and autosaves the frame.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    let defaultSize: CGSize
    let minimumSize: CGSize

    private static let autosaveName = "PromptLibraryExplorer.SettingsWindow"

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onWindow = configure(window:)
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {}

    private func configure(window: NSWindow) {
        window.styleMask.insert(.resizable)
        window.contentMinSize = minimumSize
        // Restore the saved frame, or start at the default size.
        if !window.setFrameUsingName(Self.autosaveName) {
            window.setContentSize(defaultSize)
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)
    }

    final class TrackingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private weak var configuredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== configuredWindow else { return }
            configuredWindow = window
            // After SwiftUI's own initial sizing pass.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let window else { return }
                self?.onWindow?(window)
            }
        }
    }
}
