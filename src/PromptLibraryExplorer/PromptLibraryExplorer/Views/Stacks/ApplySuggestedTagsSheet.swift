import SwiftUI

/// Apply Suggested Tags…: every selected image with its suggested tags and a checkbox
/// each. Nothing is applied until the user presses Apply and confirms.
struct ApplySuggestedTagsSheet: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Bindable var session: TagSuggestionSession
    let onClose: () -> Void

    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Apply Suggested Tags",
                subtitle: subtitle,
                systemImage: "tag.circle",
                closeTitle: "Cancel",
                onClose: onClose
            )

            if session.isLoading {
                FeatureEmptyState(
                    systemImage: "text.viewfinder",
                    title: "Looking at \(session.paths.count == 1 ? "1 image" : "\(session.paths.count) images")…",
                    message: "Images that haven't been analysed yet are analysed now. \(session.loaded) of \(session.paths.count) ready."
                ) {
                    ProgressView().controlSize(.small)
                }
            } else if session.plan.rows.isEmpty {
                FeatureEmptyState(
                    systemImage: "tag.slash",
                    title: "No suggestions",
                    message: "Nothing new to suggest for the selected images: they may already have these tags, or nothing was recognised with enough confidence."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppSpacing.sm) {
                        ForEach(session.plan.rows) { row in
                            rowView(row)
                        }
                    }
                    .padding(AppSpacing.xl)
                }
            }

            FeatureSheetFooter {
                if !session.plan.rows.isEmpty {
                    Button("Check All") { session.plan.setAll(true) }
                        .buttonStyle(AppLabeledButtonStyle(height: 28, horizontalPadding: AppSpacing.lg, cornerRadius: AppRadius.md))
                    Button("Uncheck All") { session.plan.setAll(false) }
                        .buttonStyle(AppLabeledButtonStyle(height: 28, horizontalPadding: AppSpacing.lg, cornerRadius: AppRadius.md))
                }
                Spacer(minLength: 0)
                Text("Only adds tags; existing tags are kept.")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                Button(applyTitle) { confirming = true }
                    .buttonStyle(AppPrimaryButtonStyle())
                    .disabled(session.isLoading || session.plan.checkedCount == 0)
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 520)
        .background(Color.appBackground)
        .confirmationDialog(
            "Add \(session.plan.checkedCount == 1 ? "1 tag" : "\(session.plan.checkedCount) tags") to \(session.plan.fileCount == 1 ? "1 file" : "\(session.plan.fileCount) files")?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Add Tags") {
                vm.applySuggestionPlan(session.plan, confirmed: true)
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tags that don't exist yet are created. You can remove any tag later from the Tags menu.")
        }
    }

    private var subtitle: String {
        if session.isLoading { return "Reviewing suggestions" }
        return "\(session.plan.checkedCount) of \(session.plan.rows.reduce(0) { $0 + $1.choices.count }) suggestions checked"
    }

    private var applyTitle: String {
        let count = session.plan.checkedCount
        return count == 0 ? "Apply" : "Apply \(count == 1 ? "1 Tag" : "\(count) Tags")…"
    }

    private func rowView(_ row: TagSuggestionPlan.Row) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
            FeatureThumbnail(path: row.path, size: 48)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(row.name)
                    .font(.appCalloutEmphasis)
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                SuggestionChipFlow(spacing: AppSpacing.xs) {
                    ForEach(row.choices) { choice in
                        Button {
                            session.plan.toggle(path: row.path, suggestionID: choice.id)
                        } label: {
                            HStack(spacing: AppSpacing.xs) {
                                Image(systemName: choice.isChecked ? "checkmark.square.fill" : "square")
                                    .font(.appCallout)
                                    .foregroundStyle(choice.isChecked ? Color.appAccent : Color.appMuted)
                                Text(choice.suggestion.name)
                                    .font(.appCaption)
                                    .foregroundStyle(Color.appPrimaryText)
                            }
                            .padding(.horizontal, AppSpacing.sm)
                            .padding(.vertical, AppSpacing.xxs + 1)
                            .background(Capsule(style: .continuous).fill(Color.appElevatedSurface.opacity(choice.isChecked ? 1 : 0.5)))
                        }
                        .buttonStyle(AppAdaptiveButtonStyle())
                        .accessibilityLabel(choice.suggestion.name)
                        .accessibilityValue(choice.isChecked ? "checked" : "unchecked")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Color.appSurface.opacity(0.6))
        )
    }
}
