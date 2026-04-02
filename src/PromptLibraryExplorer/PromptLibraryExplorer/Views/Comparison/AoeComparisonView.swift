import SwiftUI

/// Side-by-side comparison of two .aoe files with word-level diff highlighting.
struct AoeComparisonView: View {
    let sourceA: PromptEntry
    let sourceB: PromptEntry
    @Environment(\.dismiss) private var dismiss

    @State private var highlightUnique = true
    @State private var selectedSegments: [String: String] = [:] // key -> "a" or "b"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("AoE Comparison")
                    .font(.appTitle)
                Spacer()
                Toggle("Highlight unique words", isOn: $highlightUnique)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(12)
            .background(Color.appSurface)

            // Content
            HStack(spacing: 0) {
                // Source A
                promptStack(entry: sourceA, label: "Source A", side: "a")

                Divider().background(Color.appBorder)

                // Source B
                promptStack(entry: sourceB, label: "Source B", side: "b")
            }
        }
        .background(Color.appBackground)
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder
    private func promptStack(entry: PromptEntry, label: String, side: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header with image
                HStack(spacing: 12) {
                    if let img = entry.images.first {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipped()
                            .cornerRadius(6)
                    }

                    VStack(alignment: .leading) {
                        Text(label)
                            .font(.appTitle)
                            .foregroundStyle(Color.appAccent)
                        Text(entry.generationInfo.model)
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                    }
                }

                // Segments
                if let analysis = entry.analysis {
                    ForEach(analysis.segments, id: \.key) { segment in
                        comparisonSegment(
                            label: segment.label,
                            key: segment.key,
                            value: segment.value,
                            side: side,
                            otherValue: otherSideValue(for: segment.key, side: side)
                        )
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func comparisonSegment(
        label: String,
        key: String,
        value: String,
        side: String,
        otherValue: String?
    ) -> some View {
        let isSelected = selectedSegments[key] == side

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.appSuccess)
                        .font(.caption)
                }
            }

            if highlightUnique, let other = otherValue {
                highlightedText(value: value, reference: other)
            } else {
                Text(value)
                    .font(.appBody)
                    .foregroundStyle(Color.appPrimaryText.opacity(0.9))
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.appAccent.opacity(0.1) : Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.appAccent : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedSegments[key] = (selectedSegments[key] == side) ? nil : side
        }
    }

    // MARK: - Word Diff

    @ViewBuilder
    private func highlightedText(value: String, reference: String) -> some View {
        let words = value.split(separator: " ").map(String.init)
        let refWords = Set(reference.lowercased().split(separator: " ").map(String.init))

        Text(words.reduce(AttributedString()) { result, word in
            var attr = AttributedString(word + " ")
            if !refWords.contains(word.lowercased()) {
                attr.underlineStyle = .single
                attr.foregroundColor = Color.appPrimaryText
            } else {
                attr.foregroundColor = Color.appPrimaryText.opacity(0.6)
            }
            return result + attr
        })
        .font(.appBody)
    }

    private func otherSideValue(for key: String, side: String) -> String? {
        let otherEntry = side == "a" ? sourceB : sourceA
        return otherEntry.analysis?.segments.first(where: { $0.key == key })?.value
    }
}
