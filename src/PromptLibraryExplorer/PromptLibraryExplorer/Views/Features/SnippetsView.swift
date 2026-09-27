import SwiftUI

/// Reusable prompt fragments (vm.snippetsOpen). SnippetService is the store;
/// the view keeps a local copy refreshed after every mutation.
struct SnippetsView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var category: String?
    @State private var snippets: [PromptSnippet] = []
    @State private var categories: [String] = []
    @State private var editing: SnippetDraft?
    @State private var pendingDelete: PromptSnippet?
    @State private var hoveredID: UUID?

    private var visibleSnippets: [PromptSnippet] {
        let matches = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? snippets
            : SnippetService.shared.search(query)
        let filtered = category.map { selected in
            matches.filter { $0.category.caseInsensitiveCompare(selected) == .orderedSame }
        } ?? matches
        return filtered.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Snippets",
                subtitle: "Reusable prompt fragments",
                systemImage: "text.badge.star",
                onClose: close
            ) {
                Button {
                    editing = SnippetDraft(category: category ?? "")
                } label: {
                    Label("New Snippet", systemImage: "plus")
                        .font(.appCaption)
                }
                .buttonStyle(AppLabeledButtonStyle(height: 26, horizontalPadding: AppSpacing.md))
            }

            HStack(spacing: AppSpacing.md) {
                FeatureSearchField(placeholder: "Search snippets…", text: $query, isFocused: $searchFocused)

                Picker("Category", selection: $category) {
                    Text("All Categories").tag(String?.none)
                    if !categories.isEmpty { Divider() }
                    ForEach(categories, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.lg)

            Divider().background(Color.appBorder)

            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)

            FeatureSheetFooter {
                Text("\(visibleSnippets.count) of \(snippets.count) snippet\(snippets.count == 1 ? "" : "s")")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 560)
        .background(Color.appBackground)
        .onAppear {
            reload()
            searchFocused = true
        }
        .sheet(item: $editing) { draft in
            SnippetEditorView(draft: draft, categories: categories) { saved in
                save(saved)
            }
        }
        .alert(
            "Delete Snippet?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { snippet in
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                SnippetService.shared.delete(id: snippet.id)
                pendingDelete = nil
                reload()
            }
        } message: { snippet in
            Text("\"\(snippet.title)\" will be removed.")
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if snippets.isEmpty {
            FeatureEmptyState(
                systemImage: "text.badge.star",
                title: "No snippets yet",
                message: "Save a prompt from the Details panel with “Save as Snippet”, or create one here."
            ) {
                Button("New Snippet") { editing = SnippetDraft(category: "") }
                    .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                    .padding(.top, AppSpacing.sm)
            }
        } else if visibleSnippets.isEmpty {
            FeatureEmptyState(
                systemImage: "magnifyingglass",
                title: "No matching snippets",
                message: "Try another search or category."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: AppSpacing.sm) {
                    ForEach(visibleSnippets) { snippet in
                        snippetRow(snippet)
                    }
                }
                .padding(AppSpacing.lg)
            }
        }
    }

    private func snippetRow(_ snippet: PromptSnippet) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.sm) {
                    Text(snippet.title)
                        .font(.appCalloutEmphasis)
                        .foregroundStyle(Color.appPrimaryText)
                        .lineLimit(1)
                    if !snippet.category.isEmpty {
                        Text(snippet.category)
                            .font(.appMicro)
                            .foregroundStyle(Color.appAccent)
                            .padding(.horizontal, AppSpacing.sm)
                            .padding(.vertical, AppSpacing.xxs)
                            .background(Capsule().fill(Color.appAccent.opacity(0.14)))
                    }
                }
                Text(snippet.text)
                    .font(.appCallout)
                    .foregroundStyle(Color.appPrimaryText.opacity(0.82))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: AppSpacing.md)

            HStack(spacing: AppSpacing.xxs) {
                Button {
                    ClipboardService.copyString(snippet.text)
                    vm.showToast("Snippet copied", type: .success)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.appCaption)
                }
                .buttonStyle(AppIconButtonStyle(width: 24, height: 24, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                .help("Copy")
                .accessibilityLabel("Copy snippet")

                Button {
                    insertIntoSearch(snippet)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.appCaption)
                }
                .buttonStyle(AppIconButtonStyle(width: 24, height: 24, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                .help("Search the library for this snippet")
                .accessibilityLabel("Search library for snippet")

                Button {
                    editing = SnippetDraft(snippet)
                } label: {
                    Image(systemName: "pencil")
                        .font(.appCaption)
                }
                .buttonStyle(AppIconButtonStyle(width: 24, height: 24, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                .help("Edit")
                .accessibilityLabel("Edit snippet")

                Button {
                    pendingDelete = snippet
                } label: {
                    Image(systemName: "trash")
                        .font(.appCaption)
                }
                .buttonStyle(AppIconButtonStyle(width: 24, height: 24, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                .help("Delete")
                .accessibilityLabel("Delete snippet")
            }
        }
        .padding(AppSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(hoveredID == snippet.id ? Color.appElevatedSurface.opacity(0.6) : Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
        .onHover { hovering in
            if hovering { hoveredID = snippet.id } else if hoveredID == snippet.id { hoveredID = nil }
        }
        .onTapGesture(count: 2) { editing = SnippetDraft(snippet) }
        .contextMenu {
            Button("Copy") {
                ClipboardService.copyString(snippet.text)
                vm.showToast("Snippet copied", type: .success)
            }
            Button("Search Library for Snippet") { insertIntoSearch(snippet) }
            Divider()
            Button("Edit…") { editing = SnippetDraft(snippet) }
            Button("Delete", role: .destructive) { pendingDelete = snippet }
        }
    }

    // MARK: - Actions

    private func reload() {
        snippets = SnippetService.shared.all()
        categories = SnippetService.shared.categories
        if let category, !categories.contains(where: { $0.caseInsensitiveCompare(category) == .orderedSame }) {
            self.category = nil
        }
    }

    private func save(_ draft: SnippetDraft) {
        if let id = draft.snippetID, var existing = snippets.first(where: { $0.id == id }) {
            existing.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.text = draft.text
            existing.category = draft.category
            if existing.title.isEmpty { existing.title = String(draft.text.prefix(40)) }
            SnippetService.shared.update(existing)
        } else {
            SnippetService.shared.add(title: draft.title, text: draft.text, category: draft.category)
        }
        reload()
    }

    /// Puts the snippet text in the toolbar search (content search) and closes.
    private func insertIntoSearch(_ snippet: PromptSnippet) {
        let text = snippet.text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        close()
        vm.librarySearchQuery = text
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            vm.librarySearchOpen = true
        }
    }

    private func close() {
        vm.snippetsOpen = false
        dismiss()
    }
}

// MARK: - Editor

struct SnippetDraft: Identifiable {
    /// Presentation identity: every draft is a distinct sheet.
    let id = UUID()
    /// The snippet being edited; nil for a new one.
    var snippetID: UUID?
    var title: String = ""
    var text: String = ""
    var category: String = ""

    init(category: String) {
        self.category = category
    }

    init(_ snippet: PromptSnippet) {
        snippetID = snippet.id
        title = snippet.title
        text = snippet.text
        category = snippet.category
    }
}

private struct SnippetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: SnippetDraft
    let categories: [String]
    let onSave: (SnippetDraft) -> Void

    init(draft: SnippetDraft, categories: [String], onSave: @escaping (SnippetDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.categories = categories
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.snippetID == nil ? "New Snippet" : "Edit Snippet")
                    .font(.appTitle)
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
            }
            .padding(AppSpacing.xl)
            .background(Color.appSurface)

            Divider().background(Color.appBorder)

            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                field("Title") {
                    TextField("Optional — defaults to the first words", text: $draft.title)
                        .textFieldStyle(.roundedBorder)
                        .font(.appBody)
                }

                field("Category") {
                    HStack(spacing: AppSpacing.sm) {
                        TextField("e.g. Lighting, Style, Negative", text: $draft.category)
                            .textFieldStyle(.roundedBorder)
                            .font(.appBody)
                        if !categories.isEmpty {
                            Menu {
                                ForEach(categories, id: \.self) { name in
                                    Button(name) { draft.category = name }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.appCaption)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Choose an existing category")
                        }
                    }
                }

                field("Text") {
                    TextEditor(text: $draft.text)
                        .font(.appBody)
                        .foregroundStyle(Color.appPrimaryText)
                        .scrollContentBackground(.hidden)
                        .padding(AppSpacing.md)
                        .frame(minHeight: 140)
                        .background(Color.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                .strokeBorder(Color.appBorder, lineWidth: 1)
                        )
                }
            }
            .padding(AppSpacing.xl)

            Spacer(minLength: 0)

            FeatureSheetFooter {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
            }
        }
        .frame(width: 480, height: 420)
        .background(Color.appBackground)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(title)
                .font(.appCaptionEmphasis)
                .foregroundStyle(Color.appMuted)
            content()
        }
    }
}
