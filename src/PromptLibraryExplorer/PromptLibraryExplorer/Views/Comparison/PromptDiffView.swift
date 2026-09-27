import SwiftUI

/// Generalized prompt diff view that compares any two entries' prompts with word-level highlighting.
struct PromptDiffView: View {
    let session: PromptDiffSession
    @Environment(\.dismiss) private var dismiss
    @State private var highlightUnique = true

    private var wordsA: [String] { session.sourceA.prompt.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty } }
    private var wordsB: [String] { session.sourceB.prompt.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty } }
    private var uniqueToA: Set<String> { Set(wordsA).subtracting(Set(wordsB)) }
    private var uniqueToB: Set<String> { Set(wordsB).subtracting(Set(wordsA)) }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Prompt Comparison")
                    .font(.appTitle)
                Spacer()
                Toggle("Highlight unique words", isOn: $highlightUnique)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(AppSpacing.lg)
            .background(Color.appSurface)

            Divider().background(Color.appBorder)

            // Content
            HStack(spacing: 0) {
                diffSide(
                    entry: session.sourceA,
                    label: session.nameA,
                    words: wordsA,
                    uniqueWords: uniqueToA,
                    accentColor: .segmentSubjectText
                )

                Rectangle()
                    .fill(Color.appBorder)
                    .frame(width: 1)

                diffSide(
                    entry: session.sourceB,
                    label: session.nameB,
                    words: wordsB,
                    uniqueWords: uniqueToB,
                    accentColor: .segmentStyleText
                )
            }

            Divider().background(Color.appBorder)

            // Stats bar
            HStack(spacing: AppSpacing.xl) {
                statLabel("Words A", value: "\(wordsA.count)")
                statLabel("Words B", value: "\(wordsB.count)")
                statLabel("Shared", value: "\(Set(wordsA).intersection(Set(wordsB)).count)")
                statLabel("Unique to A", value: "\(uniqueToA.count)")
                statLabel("Unique to B", value: "\(uniqueToB.count)")
                Spacer()
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.md)
            .background(Color.appSurface)
        }
        .background(Color.appBackground)
        .frame(minWidth: 800, minHeight: 500)
    }

    @ViewBuilder
    private func diffSide(
        entry: PromptEntry,
        label: String,
        words: [String],
        uniqueWords: Set<String>,
        accentColor: Color
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                // Header
                HStack(spacing: 10) {
                    if let img = entry.images.first {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 48)
                            .clipped()
                            .cornerRadius(AppRadius.sm)
                    }

                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text(label)
                            .font(.appTitle)
                            .foregroundStyle(Color.appPrimaryText)
                        Text("\(words.count) words")
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                    }
                }

                Divider().background(Color.appBorder)

                // Prompt text with highlighted unique words
                if entry.prompt.isEmpty {
                    Text("No prompt text")
                        .font(.appBody)
                        .foregroundStyle(Color.appMuted)
                        .italic()
                } else {
                    highlightedPromptText(words: words, uniqueWords: uniqueWords, accentColor: accentColor)
                }

                // Analysis segments if available
                if let analysis = entry.analysis {
                    let segments = analysis.segments
                    if !segments.isEmpty {
                        Divider().background(Color.appBorder)

                        ForEach(segments, id: \.key) { seg in
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(seg.label)
                                    .font(.appCaptionEmphasis)
                                    .foregroundStyle(accentColor)
                                Text(seg.value)
                                    .font(.appBody)
                                    .foregroundStyle(Color.appPrimaryText.opacity(0.85))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(AppSpacing.xl)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func highlightedPromptText(words: [String], uniqueWords: Set<String>, accentColor: Color) -> some View {
        let attributed = words.enumerated().map { (index, word) -> Text in
            let isUnique = highlightUnique && uniqueWords.contains(word)
            let text = Text(word + (index < words.count - 1 ? " " : ""))
                .font(.appBody)
                .foregroundColor(isUnique ? accentColor : Color.appPrimaryText.opacity(0.9))
            return isUnique ? text.underline() : text
        }

        if let first = attributed.first {
            attributed.dropFirst().reduce(first) { $0 + $1 }
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func statLabel(_ title: String, value: String) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Text(title)
                .font(.appIcon(10, weight: .medium))
                .foregroundStyle(Color.appMuted)
            Text(value)
                .font(.appIcon(10, weight: .semibold))
                .foregroundStyle(Color.appPrimaryText)
        }
    }
}
