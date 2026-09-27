import SwiftUI

/// Compact search field that sits under a sidebar section header and filters that section.
/// Escape clears it (and drops focus when already empty).
struct SidebarFilterField: View {
    let placeholder: String
    @Binding var text: String
    var isBusy = false

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.appIcon(10, weight: .semibold))
                .foregroundStyle(isFocused ? Color.appAccent : Color.appSidebarSecondaryText)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.appCallout)
                .foregroundStyle(Color.appPrimaryText)
                .focused($isFocused)
                .onExitCommand { clearOrBlur() }
                .onKeyPress(.escape) {
                    clearOrBlur()
                    return .handled
                }
                .accessibilityLabel(placeholder)

            if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Searching")
            }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.appIcon(10))
                        .foregroundStyle(Color.appSidebarSecondaryText)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear \(placeholder)")
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .strokeBorder(isFocused ? Color.appAccent.opacity(0.6) : Color.appBorder, lineWidth: 1)
        )
        .padding(.vertical, AppSpacing.xxs)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }

    private func clearOrBlur() {
        if text.isEmpty {
            isFocused = false
        } else {
            text = ""
        }
    }
}

/// Sidebar text with every case-insensitive occurrence of `query` emphasised.
func sidebarHighlighted(_ text: String, query: String) -> AttributedString {
    var attributed = AttributedString(text)
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return attributed }
    var searchStart = text.startIndex
    while let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
        if let lower = AttributedString.Index(range.lowerBound, within: attributed),
           let upper = AttributedString.Index(range.upperBound, within: attributed) {
            attributed[lower..<upper].foregroundColor = Color.appAccent
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        searchStart = range.upperBound
    }
    return attributed
}
