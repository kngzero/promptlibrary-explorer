import SwiftUI

/// Which details sections are collapsed, by section id (usually its title). The
/// browser's details panel and the lightbox's share it; it persists.
@MainActor
@Observable
final class DetailSectionState {
    static let shared = DetailSectionState()

    @ObservationIgnored private let defaults: UserDefaults
    private var collapsed: Set<String>

    private static let collapsedKey = "collapsedDetailSections"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsed = Set(defaults.stringArray(forKey: Self.collapsedKey) ?? [])
    }

    func isExpanded(_ id: String) -> Bool { !collapsed.contains(id) }

    func setExpanded(_ expanded: Bool, for id: String) {
        guard expanded != isExpanded(id) else { return }
        if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
        defaults.set(collapsed.sorted(), forKey: Self.collapsedKey)
    }

    func binding(for id: String) -> Binding<Bool> {
        Binding(get: { self.isExpanded(id) }, set: { self.setExpanded($0, for: id) })
    }
}

/// Disclosure chevron for a details section title: right when collapsed, down
/// when expanded.
struct DetailSectionChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.appIcon(8, weight: .bold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 10)
            .accessibilityHidden(true)
    }
}

/// Makes a section's title row collapse and expand it on click (motion easeOut 0.2).
struct DetailSectionToggle<Label: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// The standard section title: chevron and title in the panel's muted caption
/// style, clickable, with optional trailing controls that stay visible collapsed.
struct DetailSectionHeader<Accessory: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            DetailSectionToggle(title: title, isExpanded: $isExpanded) {
                HStack(spacing: AppSpacing.xs) {
                    DetailSectionChevron(isExpanded: isExpanded)
                    Text(title)
                        .font(.appIcon(11, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.appMuted)
            }
            accessory()
        }
    }
}

extension DetailSectionHeader where Accessory == EmptyView {
    init(title: String, isExpanded: Binding<Bool>) {
        self.init(title: title, isExpanded: isExpanded) { EmptyView() }
    }
}

/// The details panel's card: a title above an inset surface. A titled card
/// collapses from its title. Its state is kept by title, without a trailing
/// count ("Images (12)" → "Images"), unless `sectionID` is given, or in
/// `isExpanded` when something else owns it (the histogram's View ▸ Histogram).
/// `collapsible: false` keeps a plain title (File Name).
struct DetailCard<Content: View>: View {
    let title: String?
    var sectionID: String?
    var isExpanded: Binding<Bool>?
    var collapsible = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if let title, !collapsible {
                Text(title)
                    .font(.appIcon(11, weight: .medium))
                    .foregroundStyle(Color.appMuted)
                surface
            } else if let title {
                let id = sectionID ?? title.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
                let isExpanded = self.isExpanded ?? DetailSectionState.shared.binding(for: id)
                DetailSectionHeader(title: title, isExpanded: isExpanded)
                if isExpanded.wrappedValue { surface }
            } else {
                surface
            }
        }
    }

    private var surface: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            content()
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface.opacity(0.6))
        .cornerRadius(AppRadius.lg)
    }
}
