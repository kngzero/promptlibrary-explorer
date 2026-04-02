import SwiftUI

struct HeaderBarView: View {
    @Environment(ExplorerViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        HStack(spacing: 12) {
            // Breadcrumbs
            BreadcrumbBar()

            Spacer()

            // Search — uses NSSearchField for reliable text input
            SearchFieldView(text: $vm.searchQuery)
                .frame(width: 200, height: 24)

            // Sort Menu
            Menu {
                Button("Sort by Type (A-Z)") {
                    vm.sortConfig = SortConfig(field: .type, direction: .asc)
                    vm.persistSortConfig()
                }
                Button("Sort by Type (Z-A)") {
                    vm.sortConfig = SortConfig(field: .type, direction: .desc)
                    vm.persistSortConfig()
                }
                Divider()
                Button("Sort by Name (A-Z)") {
                    vm.sortConfig = SortConfig(field: .name, direction: .asc)
                    vm.persistSortConfig()
                }
                Button("Sort by Name (Z-A)") {
                    vm.sortConfig = SortConfig(field: .name, direction: .desc)
                    vm.persistSortConfig()
                }
                Divider()
                Button("Sort by Rating (High-Low)") {
                    vm.sortConfig = SortConfig(field: .rating, direction: .asc)
                    vm.persistSortConfig()
                }
                Button("Sort by Rating (Low-High)") {
                    vm.sortConfig = SortConfig(field: .rating, direction: .desc)
                    vm.persistSortConfig()
                }
                Divider()
                Button("Custom Order") {
                    vm.sortConfig = SortConfig(field: .custom, direction: .asc)
                    vm.persistSortConfig()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: currentSortModeIcon)
                        .foregroundStyle(Color.appAccent)

                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(Color.appMuted)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(currentSortModeHelpText)

            // Filter Menu
            Menu {
                Toggle("Hide JPG", isOn: Binding(
                    get: { vm.filterConfig.hideJpg },
                    set: { vm.filterConfig.hideJpg = $0; vm.persistFilterConfig() }
                ))
                Toggle("Hide PNG", isOn: Binding(
                    get: { vm.filterConfig.hidePng },
                    set: { vm.filterConfig.hidePng = $0; vm.persistFilterConfig() }
                ))
                Toggle("Hide Other Files", isOn: Binding(
                    get: { vm.filterConfig.hideOther },
                    set: { vm.filterConfig.hideOther = $0; vm.persistFilterConfig() }
                ))
                Divider()
                Menu("Minimum Rating") {
                    Button("Show All") {
                        vm.filterConfig.filterMinRating = 0
                        vm.persistFilterConfig()
                    }
                    ForEach(1...5, id: \.self) { stars in
                        Button("\(stars)+ Stars") {
                            vm.filterConfig.filterMinRating = stars
                            vm.persistFilterConfig()
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(Color.appMuted)
                    if vm.filterConfig.activeCount > 0 {
                        Text("\(vm.filterConfig.activeCount)")
                            .font(.caption2)
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 4)
                            .background(Color.appAccent, in: Capsule())
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Thumbnails Only toggle
            Button {
                vm.thumbnailsOnly.toggle()
            } label: {
                Image(systemName: vm.thumbnailsOnly ? "text.below.photo.fill" : "text.below.photo")
                    .foregroundStyle(vm.thumbnailsOnly ? Color.appAccent : Color.appMuted)
            }
            .buttonStyle(.plain)
            .help(vm.thumbnailsOnly ? "Show file names" : "Thumbnails only")

            // Thumbnail Size
            HStack(spacing: 4) {
                Image(systemName: "square.grid.3x3")
                    .font(.caption)
                    .foregroundStyle(Color.appMuted)
                Slider(value: $vm.thumbnailSize, in: 1...10, step: 1)
                    .frame(width: 80)
                    .onChange(of: vm.thumbnailSize) { _, _ in
                        vm.persistThumbnailSize()
                    }
            }

            Button {
                Task { await vm.undoLastFolderAction() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(HeaderIconButtonStyle())
            .disabled(!vm.canUndoFolderAction)
            .help(vm.undoMenuTitle)

            Button {
                Task { await vm.redoLastFolderAction() }
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(HeaderIconButtonStyle())
            .disabled(!vm.canRedoFolderAction)
            .help(vm.redoMenuTitle)

            // Refresh
            Button {
                Task { await vm.refreshFolder() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.appBody)
            }
            .buttonStyle(HeaderLabeledButtonStyle())
            .help("Refresh")

            Button {
                vm.statisticsOpen = true
            } label: {
                Image(systemName: "chart.bar")
                    .foregroundStyle(Color.appMuted)
            }
            .buttonStyle(.plain)
            .help("Folder Statistics")

            Button {
                vm.settingsOpen = true
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(Color.appMuted)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .frame(height: LayoutMetrics.panelHeaderHeight)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) {
            Divider().background(Color.appBorder)
        }
    }

    private var currentSortModeIcon: String {
        switch vm.sortConfig.field {
        case .type:
            return "square.grid.2x2"
        case .name:
            return vm.sortConfig.direction == .asc ? "textformat.abc" : "textformat.abc.dottedunderline"
        case .custom:
            return "line.3.horizontal.decrease.circle"
        case .rating:
            return "star.fill"
        }
    }

    private var currentSortModeHelpText: String {
        switch vm.sortConfig.field {
        case .type:
            return vm.sortConfig.direction == .asc ? "Sort mode: Type (A-Z)" : "Sort mode: Type (Z-A)"
        case .name:
            return vm.sortConfig.direction == .asc ? "Sort mode: Name (A-Z)" : "Sort mode: Name (Z-A)"
        case .custom:
            return "Sort mode: Custom order"
        case .rating:
            return vm.sortConfig.direction == .asc ? "Sort mode: Rating (High-Low)" : "Sort mode: Rating (Low-High)"
        }
    }
}

private struct HeaderIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.appAccentHover : Color.appMuted)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.appBorder, lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.42)
    }
}

private struct HeaderLabeledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.appAccentHover : Color.appMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.appBorder, lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.42)
    }
}

// MARK: - NSSearchField wrapper (reliable text input that works with macOS focus system)

struct SearchFieldView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search..."
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none

        // Listen for Cmd+F to focus
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.focusField),
            name: .focusSearchField,
            object: nil
        )
        context.coordinator.field = field

        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String
        weak var field: NSSearchField?
        private var outsideClickMonitor: Any?

        init(text: Binding<String>) {
            _text = text
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            stopOutsideClickMonitoring()
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSSearchField {
                text = field.stringValue
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            startOutsideClickMonitoring()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            stopOutsideClickMonitoring()
        }

        @objc func focusField() {
            field?.window?.makeFirstResponder(field)
            field?.selectText(nil)
            startOutsideClickMonitoring()
        }

        @objc func blurField() {
            guard let field, let window = field.window else { return }
            if window.firstResponder === field || window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
            }
            stopOutsideClickMonitoring()
        }

        private func startOutsideClickMonitoring() {
            guard outsideClickMonitor == nil else { return }

            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let field = self.field, let window = field.window, event.window === window else {
                    return event
                }

                let fieldFrameInWindow = field.convert(field.bounds, to: nil)
                if !fieldFrameInWindow.contains(event.locationInWindow) {
                    self.blurField()
                }

                return event
            }
        }

        private func stopOutsideClickMonitoring() {
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
                self.outsideClickMonitor = nil
            }
        }
    }
}

// MARK: - Breadcrumb Bar

struct BreadcrumbBar: View {
    @Environment(ExplorerViewModel.self) private var vm

    var body: some View {
        HStack(spacing: 2) {
            // Up button
            if vm.selectedFolderPath != vm.explorerRootPath {
                Button {
                    if let current = vm.selectedFolderPath {
                        let parent = current.deletingLastPathComponent()
                        Task { await vm.selectFolder(parent) }
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                        .foregroundStyle(Color.appMuted)
                }
                .buttonStyle(.plain)
            }

            ForEach(Array(vm.breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                if idx > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appMuted.opacity(0.5))
                }

                Button(crumb.name) {
                    Task { await vm.selectFolder(crumb.url) }
                }
                .buttonStyle(.plain)
                .font(.appCaption)
                .foregroundStyle(
                    crumb.url == vm.selectedFolderPath ? Color.appPrimaryText : Color.appMuted
                )
                .lineLimit(1)
            }
        }
    }
}
