import SwiftUI

struct SmartFolderEditorView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State var folder: SmartFolder
    @State private var isLoadingPromptData = false
    /// Dominant-colour rule being edited (mirrored into `folder.criteria.dominantColor`).
    @State private var ruleColors: [String] = []
    @State private var ruleTolerance: Double = ColorFilter.defaultTolerance
    @State private var colorRuleOn = false
    let isNew: Bool
    var onSave: (SmartFolder) -> Void

    init(folder: SmartFolder? = nil, onSave: @escaping (SmartFolder) -> Void) {
        let f = folder ?? SmartFolder(name: "", criteria: SmartFolderCriteria())
        _folder = State(initialValue: f)
        _ruleColors = State(initialValue: f.criteria.dominantColor?.palette ?? [])
        _ruleTolerance = State(initialValue: f.criteria.dominantColor?.tolerance ?? ColorFilter.defaultTolerance)
        _colorRuleOn = State(initialValue: f.criteria.dominantColor != nil)
        self.isNew = folder == nil
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isNew ? "New Smart Folder" : "Edit Smart Folder")
                    .font(.appIcon(18, weight: .bold))
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, AppSpacing.xl)
            .background(Color.appBackground)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.appBorder).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Name
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("Name")
                            .font(.appHeadline)
                            .foregroundStyle(Color.appMuted)
                        TextField("Smart Folder Name", text: $folder.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Search Query
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("Name or Prompt Contains")
                            .font(.appHeadline)
                            .foregroundStyle(Color.appMuted)
                        TextField("Search query...", text: $folder.criteria.searchQuery)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Match mode
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("Match")
                            .font(.appHeadline)
                            .foregroundStyle(Color.appMuted)
                        Picker("Match", selection: $folder.criteria.matchMode) {
                            ForEach(SmartFolderMatchMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Match mode")
                        Text(folder.criteria.matchMode == .all
                             ? "Files must satisfy every rule below."
                             : "Files matching at least one rule below are shown.")
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                    }

                    // File Types
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        Text("File Types")
                            .font(.appHeadline)
                            .foregroundStyle(Color.appMuted)

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                        ], alignment: .leading, spacing: AppSpacing.md) {
                            ForEach(SmartFolderFileType.allCases, id: \.self) { fileType in
                                EditorCheckbox(
                                    title: fileType.displayName,
                                    isOn: Binding(
                                        get: { folder.criteria.fileTypes.contains(fileType) },
                                        set: { isOn in
                                            if isOn {
                                                folder.criteria.fileTypes.insert(fileType)
                                            } else {
                                                folder.criteria.fileTypes.remove(fileType)
                                            }
                                        }
                                    )
                                )
                            }
                        }
                    }

                    // Tags
                    if !vm.allTags.isEmpty {
                        VStack(alignment: .leading, spacing: AppSpacing.md) {
                            Text("Tagged With Any Of")
                                .font(.appHeadline)
                                .foregroundStyle(Color.appMuted)
                            TagChipFlow(spacing: AppSpacing.sm) {
                                ForEach(vm.allTags) { tag in
                                    tagChip(tag)
                                }
                            }
                        }
                    }

                    // Prompt data
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        Text("Prompt & Model")
                            .font(.appHeadline)
                            .foregroundStyle(Color.appMuted)
                        TextField("Model name contains…", text: $folder.criteria.modelContains)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Model name contains")
                        EditorCheckbox(title: "Has a prompt", isOn: $folder.criteria.requiresPrompt)
                        EditorCheckbox(title: "Has a negative prompt", isOn: $folder.criteria.requiresNegativePrompt)
                        EditorCheckbox(title: "Favorites only", isOn: $folder.criteria.favoritesOnly)
                    }

                    // Text recognised in images (Settings ▸ Search Index ▸ Text in Images).
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        Text("Text in Image")
                            .font(.appHeadline)
                            .foregroundStyle(Color.appMuted)
                        TextField("Text in image contains…", text: $folder.criteria.imageTextContains)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Text in image contains")
                        EditorCheckbox(title: "Has text in image", isOn: $folder.criteria.requiresImageText)
                    }

                    // Minimum Rating
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("Minimum Rating")
                            .font(.appHeadline)
                            .foregroundStyle(Color.appMuted)

                        Picker("", selection: $folder.criteria.minRating) {
                            Text("Any").tag(0)
                            ForEach(1...5, id: \.self) { stars in
                                Text("\(stars)+ \(String(repeating: "\u{2605}", count: stars))").tag(stars)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // Flag
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("Flag")
                            .font(.appHeadline)
                            .foregroundStyle(Color.appMuted)

                        Picker("Flag", selection: $folder.criteria.flag) {
                            Text("Any").tag(FlagFilter.all)
                            Text("Picks").tag(FlagFilter.picks)
                            Text("Not Rejected").tag(FlagFilter.hideRejects)
                            Text("Rejects").tag(FlagFilter.rejects)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Flag")
                    }

                    // Finder labels
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        Text("Finder Label Is Any Of")
                            .font(.appHeadline)
                            .foregroundStyle(Color.appMuted)
                        TagChipFlow(spacing: AppSpacing.sm) {
                            ForEach(FinderLabel.menuOrder + [.none]) { label in
                                labelChip(label)
                            }
                        }
                    }

                    // Dominant colour (visual index)
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        Text("Dominant Colour")
                            .font(.appHeadline)
                            .foregroundStyle(Color.appMuted)
                        EditorCheckbox(title: "Dominant colours match a palette", isOn: Binding(
                            get: { colorRuleOn },
                            set: { isOn in
                                colorRuleOn = isOn
                                if isOn, ruleColors.isEmpty {
                                    ruleColors = vm.filterConfig.colorFilter?.palette ?? []
                                    ruleTolerance = vm.filterConfig.colorFilter?.tolerance ?? vm.rememberedColorTolerance
                                }
                                syncColorRule()
                            }
                        ))
                        if colorRuleOn {
                            PaletteFieldsEditor(colors: $ruleColors, tolerance: $ruleTolerance, onCommit: syncColorRule)
                                .padding(.leading, AppSpacing.xl)
                            Text("Uses the colours found by the background visual index; files it hasn't reached yet don't match.")
                                .font(.appCaption)
                                .foregroundStyle(Color.appMuted)
                        }
                    }

                    // Date Range
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("Modified Date")
                            .font(.appHeadline)
                            .foregroundStyle(Color.appMuted)

                        Picker("", selection: $folder.criteria.dateRange) {
                            ForEach(SmartFolderDateRange.allCases, id: \.self) { range in
                                Text(range.displayName).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(20)
            }

            // Footer
            HStack(spacing: AppSpacing.md) {
                matchCountLabel
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    onSave(folder)
                    dismiss()
                }
                .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                .keyboardShortcut(.defaultAction)
                .disabled(folder.name.trimmingCharacters(in: .whitespaces).isEmpty || !folder.criteria.isActive)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.appBackground)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.appBorder).frame(height: 1)
            }
        }
        .frame(width: 500, height: 720)
        .background(Color.appBackground)
        .task(id: needsPromptData) {
            guard needsPromptData else { return }
            isLoadingPromptData = true
            await vm.ensurePromptIndexForCurrentListing()
            isLoadingPromptData = false
        }
        .task(id: colorRuleOn) {
            // The live match count needs the listing's dominant colours.
            if colorRuleOn { vm.loadListingDominantColorsIfNeeded(force: true) }
        }
    }

    private func syncColorRule() {
        folder.criteria.dominantColor = colorRuleOn
            ? ColorFilter(palette: ruleColors, tolerance: ruleTolerance)
            : nil
    }

    // MARK: - Live count

    private var needsPromptData: Bool {
        let c = folder.criteria
        return !c.modelContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || c.requiresPrompt || c.requiresNegativePrompt
            || !c.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var matchCount: Int? {
        guard folder.criteria.isActive else { return nil }
        let entries = vm.listingSourceContents
        guard !entries.isEmpty else { return nil }
        return SmartFolderService.filter(entries, criteria: folder.criteria, context: vm.smartFolderContext()).count
    }

    @ViewBuilder
    private var matchCountLabel: some View {
        if let matchCount {
            HStack(spacing: AppSpacing.xs) {
                if isLoadingPromptData {
                    ProgressView().controlSize(.mini)
                }
                Text(matchCount == 1 ? "1 match in current folder" : "\(matchCount) matches in current folder")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Label chips

    private func labelChip(_ label: FinderLabel) -> some View {
        let isOn = folder.criteria.labels.contains(label.rawValue)
        let title = label == .none ? "No Label" : label.title
        return Button {
            if isOn {
                folder.criteria.labels.remove(label.rawValue)
            } else {
                folder.criteria.labels.insert(label.rawValue)
            }
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Circle()
                    .fill(label == .none ? Color.clear : label.color)
                    .overlay(Circle().strokeBorder(label == .none ? Color.appMuted : Color.clear, lineWidth: 1))
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.appCallout)
                    .foregroundStyle(isOn ? Color.appPrimaryText : Color.appMuted)
                    .lineLimit(1)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.appIcon(9, weight: .bold))
                        .foregroundStyle(Color.appAccent)
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs)
            .background(Capsule().fill(isOn ? Color.appSelected : Color.appSurface))
            .overlay(Capsule().strokeBorder(isOn ? Color.appAccent.opacity(0.6) : Color.appBorder, lineWidth: 1))
        }
        .buttonStyle(AppAdaptiveButtonStyle())
        .accessibilityLabel("Label \(title)")
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Tag chips

    private func tagChip(_ tag: FileTag) -> some View {
        let isOn = folder.criteria.tagIDs.contains(tag.id)
        return Button {
            if isOn {
                folder.criteria.tagIDs.remove(tag.id)
            } else {
                folder.criteria.tagIDs.insert(tag.id)
            }
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Circle()
                    .fill(tag.color)
                    .frame(width: 8, height: 8)
                Text(tag.name)
                    .font(.appCallout)
                    .foregroundStyle(isOn ? Color.appPrimaryText : Color.appMuted)
                    .lineLimit(1)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.appIcon(9, weight: .bold))
                        .foregroundStyle(Color.appAccent)
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs)
            .background(
                Capsule().fill(isOn ? Color.appSelected : Color.appSurface)
            )
            .overlay(
                Capsule().strokeBorder(isOn ? Color.appAccent.opacity(0.6) : Color.appBorder, lineWidth: 1)
            )
        }
        .buttonStyle(AppAdaptiveButtonStyle())
        .accessibilityLabel("Tag \(tag.name)")
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Checkbox drawn with the app accent (native checkboxes tint system blue).
private struct EditorCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.appBody)
                    .foregroundStyle(isOn ? Color.appAccent : Color.appMuted)
                Text(title)
                    .font(.appCallout)
                    .foregroundStyle(Color.appPrimaryText)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Wrapping row layout for tag chips.
private struct TagChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
