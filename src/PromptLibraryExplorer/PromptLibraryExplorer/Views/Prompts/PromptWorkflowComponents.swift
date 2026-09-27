import SwiftUI

// Shared pieces of the prompt-workflow sheets (lineage, builder, statistics).

/// A token diff as styled text: added tokens green and semibold, removed
/// tokens red with a strikethrough. Text-safe colours in both modes.
struct PromptDiffTextView: View {
    let tokens: [PromptDiffToken]
    var font: Font = .appBody

    var body: some View {
        Text(Self.attributed(tokens, font: font))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ tokens: [PromptDiffToken], font: Font) -> AttributedString {
        var result = AttributedString()
        var previous: String?
        for token in tokens {
            if PromptTokenDiff.needsSpace(between: previous, and: token.text) {
                result += AttributedString(" ")
            }
            var piece = AttributedString(token.text)
            piece.font = font
            switch token.op {
            case .equal:
                piece.foregroundColor = Color.appPrimaryText.opacity(0.9)
            case .added:
                piece.foregroundColor = Color.labelGreenText
                piece.font = font.weight(.semibold)
                piece.swiftUI.underlineStyle = .single
            case .removed:
                piece.foregroundColor = Color.labelRedText
                piece.swiftUI.strikethroughStyle = .single
            }
            result += piece
            previous = token.text
        }
        return result
    }
}

/// "Added" / "Removed" key for the diff colours (identity never by colour alone:
/// added is underlined, removed is struck through).
struct PromptDiffLegend: View {
    var body: some View {
        HStack(spacing: AppSpacing.lg) {
            HStack(spacing: AppSpacing.xs) {
                Text("added")
                    .font(.appCaptionEmphasis)
                    .underline()
                    .foregroundStyle(Color.labelGreenText)
                Text("Added words")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
            HStack(spacing: AppSpacing.xs) {
                Text("removed")
                    .font(.appCaption)
                    .strikethrough()
                    .foregroundStyle(Color.labelRedText)
                Text("Removed words")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A small rounded chip: "Seed 123 → 456".
struct PromptChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .appMuted

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.appIcon(9, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(.appCaption)
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xxs + 1)
        .background(Capsule().fill(Color.appElevatedSurface))
        .overlay(Capsule().strokeBorder(Color.appBorder, lineWidth: 1))
    }
}

/// Wrapping row layout for chips.
struct PromptFlowLayout: Layout {
    var spacing: CGFloat = AppSpacing.sm
    var lineSpacing: CGFloat = AppSpacing.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let usedWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? usedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Card surface used inside the prompt-workflow sheets (matches FolderStatisticsView).
struct PromptSheetCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            if let title {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                        .font(.appHeadline)
                        .foregroundStyle(Color.appAccent)
                } else {
                    Text(title)
                        .font(.appHeadline)
                        .foregroundStyle(Color.appAccent)
                }
            }
            content
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.xl).fill(Color.appSurface))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.xl).strokeBorder(Color.appBorder, lineWidth: 1))
    }
}

/// Plain rounded text editor with a placeholder.
struct PromptTextEditor: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 80

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.appBody)
                .scrollContentBackground(.hidden)
                .padding(AppSpacing.sm)
            if text.isEmpty {
                Text(placeholder)
                    .font(.appBody)
                    .foregroundStyle(Color.appMuted)
                    .padding(.horizontal, AppSpacing.md + 1)
                    .padding(.vertical, AppSpacing.sm)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight)
        .background(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(Color.appBackground))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(Color.appControlBorder, lineWidth: 1))
    }
}
