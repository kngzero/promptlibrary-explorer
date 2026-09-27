import SwiftUI

/// Help: a searchable, sectioned reference for every feature (Browse, Prompts,
/// Cull, Find, Organise, Media, Export, Data & Sync, Integrations, Keyboard).
/// Entries with a direct entry point have "Show Me", which closes Help and runs
/// the command. Content lives in `HelpContent`; filtering in `HelpSearch`.
struct HelpView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var highlightedID: String?
    @State private var activeSection: HelpSectionID?
    @FocusState private var isSearchFocused: Bool

    private let entries = HelpContent.referenceEntries

    private var isSearching: Bool { !HelpSearch.tokens(query).isEmpty }

    private var filteredEntries: [HelpEntry] { HelpSearch.filter(entries, query: query) }

    private var filteredShortcutGroups: [HelpShortcutGroup] {
        HelpSearch.filter(HelpContent.shortcutGroups, query: query)
    }

    private func entries(in section: HelpSectionID, from list: [HelpEntry]) -> [HelpEntry] {
        list.filter { $0.section == section }
    }

    private func count(for section: HelpSectionID, entries list: [HelpEntry], groups: [HelpShortcutGroup]) -> Int {
        section == .keyboard ? groups.reduce(0) { $0 + $1.items.count } : entries(in: section, from: list).count
    }

    var body: some View {
        let list = filteredEntries
        let groups = filteredShortcutGroups

        VStack(spacing: 0) {
            header

            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    HStack(spacing: 0) {
                        sectionSidebar(list: list, groups: groups, proxy: proxy)
                        Rectangle().fill(Color.appBorder).frame(width: 1)
                        reference(list: list, groups: groups)
                    }
                    .onAppear { applyFocus(proxy: proxy) }
                    .onChange(of: query) { _, _ in
                        if let first = HelpSectionID.allCases.first(where: { count(for: $0, entries: filteredEntries, groups: filteredShortcutGroups) > 0 }) {
                            proxy.scrollTo(sectionAnchor(first), anchor: .top)
                        }
                    }
                }
            }

            footer
        }
        .frame(width: 880, height: 680)
        .background(Color.appBackground)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.appElevatedSurface)
                Image(systemName: "questionmark.circle.fill")
                    .font(.appLargeTitle)
                    .foregroundStyle(Color.appAccent)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Help")
                    .font(.appIcon(22, weight: .bold))
                    .foregroundStyle(Color.appPrimaryText)
                Text("Every feature, and how to get to it.")
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
            }

            Spacer(minLength: AppSpacing.xl)

            searchField
                .frame(width: 320)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, AppSpacing.xl)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appBorder).frame(height: 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.appMuted)
                .accessibilityHidden(true)
            TextField("Search help (e.g. duplicates, ⌘K, export)", text: $query)
                .textFieldStyle(.plain)
                .font(.appBody)
                .foregroundStyle(Color.appPrimaryText)
                .focused($isSearchFocused)
                .accessibilityLabel("Search help")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.appMuted)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .strokeBorder(isSearchFocused ? Color.appAccent.opacity(0.6) : Color.appControlBorder, lineWidth: 1)
        )
    }

    // MARK: Sidebar

    private func sectionSidebar(list: [HelpEntry], groups: [HelpShortcutGroup], proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                ForEach(HelpSectionID.allCases) { section in
                    let topicCount = count(for: section, entries: list, groups: groups)
                    Button {
                        activeSection = section
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(sectionAnchor(section), anchor: .top)
                        }
                    } label: {
                        HStack(spacing: AppSpacing.md) {
                            Image(systemName: section.icon)
                                .font(.appCallout)
                                .foregroundStyle(topicCount > 0 ? Color.appAccent : Color.appMuted)
                                .frame(width: 18)
                            Text(section.title)
                                .font(.appBody)
                                .foregroundStyle(topicCount > 0 ? Color.appPrimaryText : Color.appMuted)
                            Spacer(minLength: AppSpacing.sm)
                            Text("\(topicCount)")
                                .font(.appFootnote)
                                .foregroundStyle(Color.appMuted)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.sm)
                                .fill(activeSection == section ? Color.appSelected : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(topicCount == 0)
                    .accessibilityLabel("\(section.title), \(topicCount) topics")
                }
            }
            .padding(AppSpacing.md)
        }
        .frame(width: 190)
        .background(Color.appSurface.opacity(0.5))
    }

    // MARK: Reference

    private func reference(list: [HelpEntry], groups: [HelpShortcutGroup]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xxl) {
                if list.isEmpty, groups.isEmpty {
                    noResults
                }

                ForEach(HelpSectionID.allCases) { section in
                    if section == .keyboard {
                        if !groups.isEmpty {
                            sectionBlock(section) {
                                ForEach(groups) { group in shortcutGroupCard(group) }
                            }
                        }
                    } else {
                        let sectionEntries = entries(in: section, from: list)
                        if !sectionEntries.isEmpty {
                            sectionBlock(section) {
                                ForEach(sectionEntries) { entry in entryCard(entry) }
                            }
                        }
                    }
                }

                if !isSearching {
                    developerCard
                }
            }
            .padding(20)
        }
    }

    private func sectionAnchor(_ section: HelpSectionID) -> String { "section-\(section.rawValue)" }

    private func sectionBlock(_ section: HelpSectionID, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
                Image(systemName: section.icon)
                    .font(.appHeadline)
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)
                Text(section.title)
                    .font(.appIcon(18, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)
                    .accessibilityAddTraits(.isHeader)
                Text(section.blurb)
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                content()
            }
        }
        .id(sectionAnchor(section))
    }

    private var noResults: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "questionmark.bubble")
                .font(.appIcon(30))
                .foregroundStyle(Color.appMuted)
            Text("No help topics match \u{201C}\(query)\u{201D}")
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)
            Text("Try a shorter word, a menu name (Library, Cull) or a key such as ⌘K.")
                .font(.appCallout)
                .foregroundStyle(Color.appMuted)
            Button("Clear Search") { query = "" }
                .buttonStyle(AppLabeledButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: Entry

    private func isExpanded(_ entry: HelpEntry) -> Bool {
        isSearching || expanded.contains(entry.id) || highlightedID == entry.id
    }

    private func entryCard(_ entry: HelpEntry) -> some View {
        let open = isExpanded(entry)
        let isHighlighted = highlightedID == entry.id

        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.appAccent)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.xxs)
                    .background(Capsule().fill(Color.appAccent.opacity(0.12)))

                Text(entry.title)
                    .font(.appIcon(15, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)

                Spacer(minLength: AppSpacing.md)

                if let command = entry.showMe {
                    showMeButton(command)
                }
            }

            Text(entry.summary)
                .font(.appBody)
                .foregroundStyle(Color.appPrimaryText.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            if !entry.details.isEmpty {
                if open {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        ForEach(entry.details, id: \.self) { detail in
                            HStack(alignment: .top, spacing: AppSpacing.md) {
                                Image(systemName: "circle.fill")
                                    .font(.appIcon(4))
                                    .foregroundStyle(Color.appAccent)
                                    .padding(.top, 6)
                                    .accessibilityHidden(true)
                                Text(detail)
                                    .font(.appCallout)
                                    .foregroundStyle(Color.appMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if !isSearching {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                            if highlightedID == entry.id { highlightedID = nil }
                        }
                    } label: {
                        Label(open ? "Less" : "More (\(entry.details.count))", systemImage: open ? "chevron.up" : "chevron.down")
                            .font(.appCaption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccentHover)
                    .accessibilityLabel(open ? "Show less about \(entry.title)" : "Show more about \(entry.title)")
                }
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(isHighlighted ? Color.appAccent : Color.appBorder, lineWidth: isHighlighted ? 1.5 : 1)
        )
        .id(entry.id)
    }

    private func showMeButton(_ command: HelpCommand) -> some View {
        let available = vm.canPerform(command)
        return HStack(spacing: AppSpacing.sm) {
            Text(command.locationText)
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
            Button {
                vm.performAfterDismissingSheets(command)
            } label: {
                Label("Show Me", systemImage: "arrow.up.forward.app")
                    .font(.appCaptionEmphasis)
            }
            .buttonStyle(AppLabeledButtonStyle(height: 22, horizontalPadding: AppSpacing.md))
            .disabled(!available)
            .help(available ? "Close Help and open \(command.locationText)" : vm.unavailableHint(for: command))
            .accessibilityHint(available ? "Opens \(command.locationText)" : vm.unavailableHint(for: command))
        }
        .fixedSize()
    }

    // MARK: Keyboard

    private func shortcutGroupCard(_ group: HelpShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(group.title)
                    .font(.appIcon(15, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)
                Text(group.description)
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: AppSpacing.md) {
                ForEach(group.items) { item in
                    HStack(alignment: .top, spacing: 14) {
                        HStack(spacing: AppSpacing.xs) {
                            ForEach(item.keys, id: \.self) { key in
                                shortcutKey(key)
                            }
                        }
                        .frame(minWidth: 180, alignment: .leading)

                        Text(item.description)
                            .font(.appCallout)
                            .foregroundStyle(Color.appPrimaryText.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private func shortcutKey(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.appPrimaryText)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .fill(Color.appBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .strokeBorder(Color.appControlBorder, lineWidth: 1)
            )
    }

    // MARK: Developer, footer

    private var developerCard: some View {
        let resource = HelpContent.developerResource

        return HStack(alignment: .center, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(resource.title)
                    .font(.appIcon(15, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)
                Text(resource.description)
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AppSpacing.md)
            Button {
                vm.openDeveloperWebsite()
            } label: {
                Label(resource.buttonTitle, systemImage: "arrow.up.right.square")
                    .font(.appCalloutEmphasis)
            }
            // The text-safe teal with the canvas colour as its label stays above
            // 6:1 in both modes.
            .buttonStyle(
                AppPrimaryButtonStyle(
                    tint: .segmentPlaceText,
                    foreground: .appCanvasBackground,
                    horizontalPadding: AppSpacing.lg,
                    verticalPadding: AppSpacing.sm,
                    cornerRadius: AppRadius.md
                )
            )
        }
        .padding(AppSpacing.xl)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.appElevatedSurface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: AppSpacing.lg) {
            Button {
                vm.performAfterDismissingSheets(.welcomeTour)
            } label: {
                Label("Welcome Tour…", systemImage: "sparkles")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appAccentHover)
            .help("Close Help and replay the welcome tour")

            Button {
                OnboardingTipsController.shared.reset()
            } label: {
                Label("Reset Tips", systemImage: "lightbulb")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appAccentHover)
            .help("Show every tip again as you use the app")

            Spacer()

            Text("\(entries.count) topics")
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)

            // Esc closes Help. Return is left to the search field.
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, AppSpacing.lg)
        .background(Color.appBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.appBorder).frame(height: 1)
        }
    }

    // MARK: Focus

    /// Opened for a specific entry or section (a tip's ?, the palette's "Help: …",
    /// Help ▸ Keyboard Shortcuts): scroll there and highlight it.
    private func applyFocus(proxy: ScrollViewProxy) {
        guard let focus = OnboardingController.shared.helpFocus else {
            isSearchFocused = true
            return
        }
        OnboardingController.shared.helpFocus = nil
        DispatchQueue.main.async {
            switch focus {
            case .entry(let id):
                highlightedID = id
                activeSection = entries.first { $0.id == id }?.section
                proxy.scrollTo(id, anchor: .top)
            case .section(let section):
                activeSection = section
                proxy.scrollTo(sectionAnchor(section), anchor: .top)
            }
        }
    }
}
