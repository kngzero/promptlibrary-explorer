import SwiftUI

/// Inline tag pills shown on grid items and detail panel.
struct TagPillsView: View {
    let tags: [FileTag]
    var compact: Bool = false

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: AppSpacing.xxs) {
                ForEach(tags.prefix(compact ? 3 : 10)) { tag in
                    if compact {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 6, height: 6)
                    } else {
                        Text(tag.name)
                            .font(.appIcon(9, weight: .medium))
                            .foregroundStyle(Self.labelColor(onHex: tag.colorHex))
                            .padding(.horizontal, 5)
                            .padding(.vertical, AppSpacing.xxs)
                            .background(tag.color.opacity(0.85))
                            .cornerRadius(AppRadius.xs)
                    }
                }
                if compact && tags.count > 3 {
                    Text("+\(tags.count - 3)")
                        .font(.appIcon(8, weight: .medium))
                        .foregroundStyle(Color.appMuted)
                }
            }
        }
    }
}

extension TagPillsView {
    /// White or near-black label, whichever contrasts more with the tag fill.
    /// White on the preset yellow/green/cyan tags was ~2:1.
    static func labelColor(onHex hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&rgb) else { return .white }
        func linear(_ component: UInt64) -> Double {
            let c = Double(component & 0xFF) / 255.0
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb >> 16) + 0.7152 * linear(rgb >> 8) + 0.0722 * linear(rgb)
        let whiteContrast = 1.05 / (luminance + 0.05)
        let darkContrast = (luminance + 0.05) / 0.0565 // #121212
        return whiteContrast >= darkContrast ? .white : Color(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0)
    }
}

/// Tag assignment menu for context menus.
struct TagAssignmentMenu: View {
    @Environment(ExplorerViewModel.self) private var vm
    let paths: [String]

    var body: some View {
        if vm.allTags.isEmpty {
            Text("No tags created")
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
        } else {
            ForEach(vm.allTags) { tag in
                Button {
                    for path in paths {
                        vm.toggleTagForFile(tag.id, path: path)
                    }
                } label: {
                    HStack(spacing: AppSpacing.sm) {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 8, height: 8)
                        Text(tag.name)
                        if paths.count == 1, let path = paths.first, vm.fileHasTag(tag.id, path: path) {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }
}

/// Tag creation popover.
struct TagCreatorView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var tagName = ""
    @State private var selectedColor = FileTag.presetColors[0]
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            Text("New Tag")
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)

            TextField("Tag name", text: $tagName)
                .textFieldStyle(.roundedBorder)
                .font(.appBody)

            // Color picker
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: AppSpacing.sm), count: 8), spacing: AppSpacing.sm) {
                ForEach(FileTag.presetColors, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle()
                                .strokeBorder(selectedColor == hex ? Color.appPrimaryText : Color.clear, lineWidth: 2)
                        )
                        .onTapGesture { selectedColor = hex }
                        .help(Self.colorName(for: hex))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Self.colorName(for: hex))
                        .accessibilityAddTraits(selectedColor == hex ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { selectedColor = hex }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onDone() }
                Button("Create") {
                    let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    vm.addTag(name: trimmed, colorHex: selectedColor)
                    onDone()
                }
                .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                .disabled(tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppSpacing.xl)
        .frame(width: 260)
    }

    /// Spoken/tooltip names for `FileTag.presetColors`.
    static func colorName(for hex: String) -> String {
        switch hex.uppercased() {
        case "#EF4444": return "Red"
        case "#F97316": return "Orange"
        case "#EAB308": return "Yellow"
        case "#22C55E": return "Green"
        case "#06B6D4": return "Cyan"
        case "#3B82F6": return "Blue"
        case "#8B5CF6": return "Purple"
        case "#EC4899": return "Pink"
        default: return "Colour \(hex)"
        }
    }
}

/// Sidebar section for filtering by tags.
struct TagFilterSidebarView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var showTagCreator = false
    @AppStorage("sidebar.tags.expanded") private var tagsExpanded = true

    var body: some View {
        Group {
            SidebarSectionHeader(title: "Tags", isExpanded: $tagsExpanded)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            if tagsExpanded {
            ForEach(vm.allTags) { tag in
                Button {
                    vm.filterByTagID = vm.filterByTagID == tag.id ? nil : tag.id
                } label: {
                    HStack(spacing: AppSpacing.md) {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)

                        Text(tag.name)
                            .lineLimit(1)

                        Spacer()

                        if vm.filterByTagID == tag.id {
                            Image(systemName: "checkmark")
                                .font(.appIcon(10, weight: .semibold))
                                .foregroundStyle(Color.appAccent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AppLabeledButtonStyle(height: 26, horizontalPadding: 6, cornerRadius: AppRadius.sm, showsRestingChrome: false, restingForeground: Color.appSidebarText))
                .font(.appSidebarItem)
                .padding(.vertical, AppSpacing.xxs)
                .accessibilityLabel("Tag \(tag.name)")
                .accessibilityHint("Filters the folder by this tag")
                .accessibilityAddTraits(vm.filterByTagID == tag.id ? .isSelected : [])
                .accessibilityAction(named: "Delete Tag") {
                    vm.removeTag(id: tag.id)
                }
                .contextMenu {
                    Button("Delete Tag", role: .destructive) {
                        vm.removeTag(id: tag.id)
                    }
                }
            }

            Button {
                showTagCreator = true
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 18)
                    Text("New Tag")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(AppLabeledButtonStyle(height: 26, horizontalPadding: 6, cornerRadius: AppRadius.sm, showsRestingChrome: false, restingForeground: Color.appSidebarText))
                .font(.appSidebarItem)
            .popover(isPresented: $showTagCreator) {
                TagCreatorView { showTagCreator = false }
                    .environment(vm)
            }
            }
        }
    }
}
