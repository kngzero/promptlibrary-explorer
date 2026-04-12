import SwiftUI

/// Inline tag pills shown on grid items and detail panel.
struct TagPillsView: View {
    let tags: [FileTag]
    var compact: Bool = false

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 3) {
                ForEach(tags.prefix(compact ? 3 : 10)) { tag in
                    if compact {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 6, height: 6)
                    } else {
                        Text(tag.name)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(tag.color.opacity(0.85))
                            .cornerRadius(4)
                    }
                }
                if compact && tags.count > 3 {
                    Text("+\(tags.count - 3)")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color.appMuted)
                }
            }
        }
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
                    HStack(spacing: 6) {
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
        VStack(alignment: .leading, spacing: 12) {
            Text("New Tag")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appPrimaryText)

            TextField("Tag name", text: $tagName)
                .textFieldStyle(.roundedBorder)
                .font(.appBody)

            // Color picker
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 8), spacing: 6) {
                ForEach(FileTag.presetColors, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle()
                                .strokeBorder(selectedColor == hex ? Color.white : Color.clear, lineWidth: 2)
                        )
                        .onTapGesture { selectedColor = hex }
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
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .disabled(tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

/// Sidebar section for filtering by tags.
struct TagFilterSidebarView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var showTagCreator = false

    var body: some View {
        Section {
            ForEach(vm.allTags) { tag in
                Button {
                    vm.filterByTagID = vm.filterByTagID == tag.id ? nil : tag.id
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 10, height: 10)

                        Text(tag.name)
                            .lineLimit(1)

                        Spacer()

                        if vm.filterByTagID == tag.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.appAccent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Delete Tag") {
                        vm.removeTag(id: tag.id)
                    }
                }
            }

            Button {
                showTagCreator = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 18)
                    Text("New Tag")
                        .foregroundStyle(Color.appMuted)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showTagCreator) {
                TagCreatorView { showTagCreator = false }
                    .environment(vm)
            }
        } header: {
            SidebarSectionHeader(title: "Tags")
        }
    }
}
