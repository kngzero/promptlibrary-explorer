import SwiftUI

/// Template-based rename of the selection, or the whole listing when nothing
/// is selected (vm.batchRenameOpen).
struct BatchRenameView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @AppStorage("batchRename.lastTemplate") private var template = "{name}_{counter:3}"
    @FocusState private var templateFocused: Bool
    @State private var plan: [RenamePlanItem] = []
    @State private var isPlanning = false
    @State private var isApplying = false

    private var targetCount: Int { vm.batchRenameTargets.count }
    private var changeCount: Int { plan.filter { !$0.unchanged && !$0.conflict }.count }
    private var conflictCount: Int { plan.filter(\.conflict).count }
    private var unchangedCount: Int { plan.filter { $0.unchanged && !$0.conflict }.count }
    private var canRename: Bool {
        !isApplying && !isPlanning && changeCount > 0 && conflictCount == 0
            && !template.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Batch Rename",
                subtitle: vm.selectedFileItems.isEmpty
                    ? "Renaming all \(targetCount) file\(targetCount == 1 ? "" : "s") in this listing"
                    : "Renaming \(targetCount) selected file\(targetCount == 1 ? "" : "s")",
                systemImage: "character.cursor.ibeam",
                closeTitle: "Cancel",
                onClose: close
            )

            templateEditor
                .padding(.horizontal, AppSpacing.xl)
                .padding(.vertical, AppSpacing.lg)

            Divider().background(Color.appBorder)

            previewTable
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)

            FeatureSheetFooter {
                statusSummary
                Spacer()
                if isApplying {
                    ProgressView().controlSize(.small)
                }
                Button("Rename \(changeCount > 0 ? "\(changeCount) " : "")File\(changeCount == 1 ? "" : "s")") {
                    apply()
                }
                .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                .keyboardShortcut(.defaultAction)
                .disabled(!canRename)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 560)
        .background(Color.appBackground)
        .onAppear { templateFocused = true }
        .task(id: template) {
            // Debounce typing; a newer template cancels this task.
            isPlanning = true
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let next = await vm.batchRenamePlan(template: template)
            guard !Task.isCancelled else { return }
            plan = next
            isPlanning = false
        }
    }

    // MARK: - Template editor

    private var templateEditor: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Name Template")
                .font(.appCaptionEmphasis)
                .foregroundStyle(Color.appMuted)

            HStack(spacing: AppSpacing.md) {
                TextField("e.g. {date}_{model}_{counter:3}", text: $template)
                    .textFieldStyle(.plain)
                    .font(.appMono)
                    .foregroundStyle(Color.appPrimaryText)
                    .focused($templateFocused)
                    .onSubmit { if canRename { apply() } }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .fill(Color.appSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .strokeBorder(templateFocused ? Color.appAccent.opacity(0.6) : Color.appControlBorder, lineWidth: 1)
                    )

                Menu {
                    ForEach(RenameTemplateService.tokens, id: \.token) { token in
                        Button {
                            insert(token.token)
                        } label: {
                            Text("\(token.token) — \(token.description)")
                        }
                    }
                } label: {
                    Label("Insert Token", systemImage: "curlybraces")
                        .font(.appCaption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Color.appMuted)
                .help("Insert a template token")
            }

            Text("The original extension is kept unless the template includes {ext}. Names that collide are flagged and must be resolved before renaming.")
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)
        }
    }

    private func insert(_ token: String) {
        // Tokens with a placeholder argument insert a sensible default.
        let concrete: String
        switch token {
        case "{date:FORMAT}": concrete = "{date:yyyyMMdd}"
        case "{prompt:N}": concrete = "{prompt:40}"
        case "{counter:N}": concrete = "{counter:3}"
        default: concrete = token
        }
        let separator = template.isEmpty || template.hasSuffix("_") || template.hasSuffix("-") || template.hasSuffix(" ") ? "" : "_"
        template += separator + concrete
        templateFocused = true
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewTable: some View {
        if targetCount == 0 {
            FeatureEmptyState(
                systemImage: "doc.on.doc",
                title: "No files to rename",
                message: "Select files in the grid, or open a folder that contains files."
            )
        } else if plan.isEmpty {
            VStack(spacing: AppSpacing.md) {
                ProgressView().controlSize(.small)
                Text("Building preview…")
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: AppSpacing.md) {
                    Text("Current Name")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .opacity(0)
                    Text("New Name")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 18)
                }
                .font(.appCaptionEmphasis)
                .foregroundStyle(Color.appMuted)
                .padding(.horizontal, AppSpacing.xl)
                .padding(.vertical, AppSpacing.sm)
                .background(Color.appSurface.opacity(0.5))

                Divider().background(Color.appBorder)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(plan) { item in
                            planRow(item)
                            Divider().background(Color.appBorder.opacity(0.5))
                        }
                    }
                }
                .opacity(isPlanning ? 0.6 : 1)
            }
        }
    }

    private func planRow(_ item: RenamePlanItem) -> some View {
        HStack(spacing: AppSpacing.md) {
            Text(item.source.lastPathComponent)
                .font(.appCallout)
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.appCaption)
                .foregroundStyle(Color.appMuted.opacity(0.6))

            Text(item.proposedName)
                .font(.appCalloutEmphasis)
                .foregroundStyle(item.conflict ? Color.appError : (item.unchanged ? Color.appMuted : Color.appPrimaryText))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.proposedName)

            Group {
                if item.conflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.appError)
                        .help("Another file already has, or would get, this name")
                } else if item.unchanged {
                    Image(systemName: "equal.circle")
                        .foregroundStyle(Color.appMuted)
                        .help("Name is unchanged")
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.appSuccess)
                }
            }
            .font(.appCallout)
            .frame(width: 18)
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.sm)
        .background(item.conflict ? Color.appError.opacity(0.08) : Color.clear)
    }

    private var statusSummary: some View {
        HStack(spacing: AppSpacing.lg) {
            summaryChip("\(changeCount) to rename", systemImage: "checkmark.circle.fill", color: .appSuccess)
            if conflictCount > 0 {
                summaryChip("\(conflictCount) conflict\(conflictCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill", color: .appError)
            }
            if unchangedCount > 0 {
                summaryChip("\(unchangedCount) unchanged", systemImage: "equal.circle", color: .appMuted)
            }
            if isPlanning {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func summaryChip(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(text)
                .foregroundStyle(Color.appMuted)
        }
        .font(.appCaption)
    }

    // MARK: - Actions

    private func apply() {
        guard canRename else { return }
        isApplying = true
        let current = plan
        Task {
            await vm.applyBatchRename(current)
            isApplying = false
            close()
        }
    }

    private func close() {
        vm.batchRenameOpen = false
        dismiss()
    }
}
