import AppKit
import SwiftUI

// Shared chrome for the feature sheets (Library Search, Similar Prompts,
// Batch Rename, Snippets). Matches the header / footer treatment of
// BatchMetadataEditorView and PromptDiffView.

/// Title bar for a feature sheet: icon + title (+ subtitle) on the left, a
/// trailing slot, and a Close button that owns Escape (`.cancelAction`).
struct FeatureSheetHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String
    var closeTitle: String = "Close"
    let onClose: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: systemImage)
                    .font(.appIcon(15, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(title)
                        .font(.appTitle)
                        .foregroundStyle(Color.appPrimaryText)
                    if let subtitle {
                        Text(subtitle)
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                    }
                }
                Spacer(minLength: AppSpacing.lg)
                trailing()
                Button(closeTitle, action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.lg)
            .background(Color.appSurface)

            Divider().background(Color.appBorder)
        }
    }
}

extension FeatureSheetHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String, closeTitle: String = "Close", onClose: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage, closeTitle: closeTitle, onClose: onClose) {
            EmptyView()
        }
    }
}

/// Bottom action bar for a feature sheet.
struct FeatureSheetFooter<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Divider().background(Color.appBorder)
            HStack(spacing: AppSpacing.md) {
                content()
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.lg)
            .background(Color.appSurface)
        }
    }
}

/// Centered icon + title + message placeholder for empty / loading states.
struct FeatureEmptyState<Accessory: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: systemImage)
                .font(.appIcon(32))
                .foregroundStyle(Color.appMuted.opacity(0.6))
            Text(title)
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)
            if let message {
                Text(message)
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            accessory()
        }
        .padding(AppSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension FeatureEmptyState where Accessory == EmptyView {
    init(systemImage: String, title: String, message: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// Rounded search field used at the top of the feature sheets.
struct FeatureSearchField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.appCallout)
                .foregroundStyle(Color.appMuted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.appIcon(14))
                .foregroundStyle(Color.appPrimaryText)
                .focused(isFocused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.appCallout)
                }
                .buttonStyle(AppIconButtonStyle(width: 20, height: 20, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                .help("Clear")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Color.appBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(Color.appControlBorder, lineWidth: 1)
        )
    }
}

/// Small file thumbnail loaded through ThumbnailService (images and video),
/// falling back to a file-type glyph.
struct FeatureThumbnail: View {
    let path: String
    var size: CGFloat = 44

    @State private var image: NSImage?

    private var url: URL { URL(fileURLWithPath: path) }
    private var name: String { url.lastPathComponent }

    private var glyph: String {
        if FileHelpers.isVideoFile(name) { return "film" }
        if FileHelpers.isAudioFile(name) { return "waveform" }
        if FileHelpers.isPromptSnapshotFile(name) { return "doc.richtext" }
        if FileHelpers.isMoodboardFile(name) { return "square.grid.3x3.square" }
        if FileHelpers.isStoryFile(name) { return "film.stack" }
        if FileHelpers.isImageFile(name) { return "photo" }
        return "doc"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                .fill(Color.appSurface)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: glyph)
                    .font(.appIcon(size * 0.36))
                    .foregroundStyle(Color.appMuted.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
        .task(id: path) {
            image = nil
            guard FileHelpers.isImageFile(name) || FileHelpers.isVideoFile(name) else { return }
            if let cached = ThumbnailService.shared.cachedThumbnail(for: url, size: size * 2) {
                image = cached
                return
            }
            let loaded = await ThumbnailService.shared.thumbnail(for: url, size: size * 2)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

enum FeatureText {
    /// Renders a snippet whose matched terms are wrapped in «» as an
    /// AttributedString with the matches accent-coloured and emphasised.
    static func highlightedSnippet(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var remaining = Substring(snippet)
        while let open = remaining.firstIndex(of: "«") {
            result += AttributedString(String(remaining[..<open]))
            let afterOpen = remaining.index(after: open)
            guard let close = remaining[afterOpen...].firstIndex(of: "»") else {
                remaining = remaining[afterOpen...]
                break
            }
            var match = AttributedString(String(remaining[afterOpen..<close]))
            match.foregroundColor = Color.appAccent
            match.font = .appCalloutEmphasis
            result += match
            remaining = remaining[remaining.index(after: close)...]
        }
        result += AttributedString(String(remaining).replacingOccurrences(of: "»", with: ""))
        return result
    }

    /// Path of `folder` relative to `root` ("" for the root itself); falls
    /// back to a tilde-abbreviated absolute path outside the root.
    static func relativeFolder(_ folder: String, root: URL?) -> String {
        let folderPath = URL(fileURLWithPath: folder).standardizedFileURL.path
        if let rootPath = root?.standardizedFileURL.path {
            if folderPath == rootPath { return root?.lastPathComponent ?? "" }
            if folderPath.hasPrefix(rootPath + "/") {
                let relative = String(folderPath.dropFirst(rootPath.count + 1))
                return (root?.lastPathComponent ?? "") + "/" + relative
            }
        }
        return (folderPath as NSString).abbreviatingWithTildeInPath
    }

    /// First line of a prompt, flattened and truncated.
    static func truncated(_ text: String, limit: Int = 220) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}

/// Styled row background for list selections inside the feature sheets.
struct FeatureRowBackground: View {
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
            .fill(isSelected ? Color.appSelected : (isHovered ? Color.appHover : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(isSelected ? Color.appAccent.opacity(0.45) : Color.clear, lineWidth: 1)
            )
    }
}
