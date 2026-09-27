import AppKit
import SwiftUI

// MARK: - Menu swatches

extension FinderLabel {
    /// A non-template colour dot for menus (menus draw SF Symbols monochrome).
    /// Uses Finder's own label colour from `NSWorkspace.fileLabelColors`.
    var menuSwatch: NSImage {
        let colors = NSWorkspace.shared.fileLabelColors
        let fill: NSColor = rawValue < colors.count && self != .none ? colors[rawValue] : .clear
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            fill.setFill()
            dot.fill()
            NSColor.secondaryLabelColor.setStroke()
            dot.lineWidth = self == .none ? 1 : 0.5
            dot.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Menu title, with the bare key when it has one ("Red (6)").
    var menuTitle: String {
        keyHint.map { "\(title) (\($0))" } ?? title
    }
}

extension FileFlag {
    /// Menu title with its bare key ("Pick (P)").
    var menuTitle: String { "\(actionTitle) (\(keyHint))" }

    /// Menu / picker order.
    static let menuOrder: [FileFlag] = [.pick, .reject, .unflagged]
}

enum CullMenuText {
    /// "No Rating (0)", "★★★ (3)".
    static func rating(_ stars: Int) -> String {
        stars == 0 ? "No Rating (0)" : "\(String(repeating: "\u{2605}", count: stars)) (\(stars))"
    }
}

/// Flag ▸, Label ▸ and Rating ▸ submenus. Checkmarks show the state when every
/// target agrees (`nil` = mixed).
struct CullActionMenus: View {
    let flag: FileFlag?
    let rating: Int?
    let label: FinderLabel?
    /// False when every target is a folder: only Label ▸ applies then.
    var includesFileActions = true
    let perform: (CullAction) -> Void

    var body: some View {
        if includesFileActions {
            Menu("Flag") {
                ForEach(FileFlag.menuOrder) { option in
                    Toggle(option.menuTitle, isOn: Binding(
                        get: { flag == option },
                        set: { _ in perform(.flag(option)) }
                    ))
                }
            }
        }

        Menu("Label") {
            ForEach(FinderLabel.menuOrder) { option in
                labelToggle(option)
            }
            Divider()
            labelToggle(.none)
        }

        if includesFileActions {
            Menu("Rating") {
                ForEach(0...5, id: \.self) { stars in
                    Toggle(CullMenuText.rating(stars), isOn: Binding(
                        get: { rating == stars },
                        set: { _ in perform(.rating(stars)) }
                    ))
                }
            }
        }
    }

    private func labelToggle(_ option: FinderLabel) -> some View {
        Toggle(isOn: Binding(
            get: { label == option },
            set: { _ in perform(.label(option)) }
        )) {
            Label {
                Text(option == .none ? "No Label" : option.menuTitle)
            } icon: {
                Image(nsImage: option.menuSwatch)
            }
        }
    }
}

// MARK: - Grid tile badges

/// Top-trailing tile badges: Finder label dot and pick / reject flag.
struct TileCullBadges: View {
    let flag: FileFlag
    let label: FinderLabel
    let side: CGFloat

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            if label != .none {
                Circle()
                    .fill(label.color)
                    .frame(width: side * 0.5, height: side * 0.5)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: Color.appShadowColor, radius: 2, y: 1)
                    .accessibilityLabel("\(label.title) label")
            }
            switch flag {
            case .pick:
                badge(systemImage: "flag.fill", fill: .appAccent, glyph: .appOnAccent)
                    .accessibilityLabel("Pick")
            case .reject:
                badge(systemImage: "xmark", fill: .appError, glyph: .white)
                    .accessibilityLabel("Rejected")
            case .unflagged:
                EmptyView()
            }
        }
    }

    private func badge(systemImage: String, fill: Color, glyph: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: side * 0.42, weight: .bold))
            .foregroundStyle(glyph)
            .frame(width: side * 0.8, height: side * 0.8)
            .background(Circle().fill(fill))
            .shadow(color: Color.appShadowColor, radius: 2, y: 1)
    }
}

// MARK: - List cells

struct FlagCell: View {
    let flag: FileFlag

    var body: some View {
        if flag == .unflagged {
            Text("")
        } else {
            Image(systemName: flag.systemImage)
                .font(.appIcon(12, weight: .semibold))
                .foregroundStyle(flag.tint)
                .help(flag.title)
                .accessibilityLabel(flag.title)
        }
    }
}

struct LabelCell: View {
    let label: FinderLabel

    var body: some View {
        if label == .none {
            Text("")
        } else {
            HStack(spacing: AppSpacing.xs) {
                Circle().fill(label.color).frame(width: 8, height: 8)
                Text(label.title)
                    .font(.appCaption)
                    .foregroundStyle(label.textColor)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Details panel controls

/// Pick / Unflagged / Reject segmented control.
struct FlagSegmentedControl: View {
    let flag: FileFlag
    let onSet: (FileFlag) -> Void

    private static let order: [FileFlag] = [.pick, .unflagged, .reject]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.order) { option in
                let isOn = option == flag
                Button {
                    onSet(option)
                } label: {
                    Image(systemName: option == .unflagged ? "flag.slash" : option.systemImage)
                        .font(.appIcon(12, weight: .semibold))
                        .foregroundStyle(isOn ? (option == .unflagged ? Color.appPrimaryText : option.tint) : Color.appMuted)
                        .frame(width: 30, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.sm)
                                .fill(isOn ? Color.appElevatedSurface : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(option.actionTitle) (\(option.keyHint))")
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(AppSpacing.xxs)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.appSurface))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(Color.appBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Flag")
    }
}

/// None + Finder's seven colour swatches.
struct LabelSwatchRow: View {
    let label: FinderLabel
    var swatchSize: CGFloat = 14
    let onSelect: (FinderLabel) -> Void

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            swatch(.none)
            ForEach(FinderLabel.menuOrder) { option in
                swatch(option)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Finder Label")
    }

    private func swatch(_ option: FinderLabel) -> some View {
        let isOn = option == label
        return Button {
            onSelect(option)
        } label: {
            ZStack {
                if option == .none {
                    Circle().strokeBorder(Color.appMuted, lineWidth: 1)
                    Image(systemName: "xmark")
                        .font(.system(size: swatchSize * 0.45, weight: .bold))
                        .foregroundStyle(Color.appMuted)
                } else {
                    Circle().fill(option.color)
                }
            }
            .frame(width: swatchSize, height: swatchSize)
            .padding(2)
            .overlay(Circle().strokeBorder(isOn ? Color.appPrimaryText : Color.clear, lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(option == .none ? "No Label" : option.menuTitle)
        .accessibilityLabel(option == .none ? "No Label" : option.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Lightbox culling HUD

/// Compact, large-type culling status over the lightbox canvas: flag, stars,
/// label, position and key hints. Flashes each action.
struct CullingHUD: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: FileEntry

    @State private var flash: CullFeedback?

    private var flag: FileFlag { vm.flag(for: item.path) }
    private var rating: Int { vm.rating(for: item.path) }
    private var label: FinderLabel { FinderLabel(labelNumber: item.labelNumber) }

    /// "n / m" among the previewable items of the listing.
    private var positionText: String {
        let items = vm.processedFolderContents
        var total = 0
        var position = 0
        for (index, entry) in items.enumerated() where FileHelpers.isPreviewable(entry) {
            total += 1
            if index == vm.lightboxIndex { position = total }
        }
        return position > 0 ? "\(position) / \(total)" : "– / \(total)"
    }

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            statusBar
            Spacer(minLength: 0)
            if let flash {
                flashBadge(flash)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, AppSpacing.xl)
        .allowsHitTesting(false)
        .onChange(of: vm.cullFeedback) { _, feedback in
            guard let feedback else { return }
            withAnimation(.easeOut(duration: 0.12)) { flash = feedback }
            let id = feedback.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard flash?.id == id else { return }
                withAnimation(.easeIn(duration: 0.25)) { flash = nil }
            }
        }
    }

    private var statusBar: some View {
        VStack(spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.xl) {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: flag == .unflagged ? "flag" : flag.systemImage)
                        .foregroundStyle(flag.tint)
                    Text(flag.title)
                        .foregroundStyle(flag == .unflagged ? Color.appMuted : Color.appPrimaryText)
                }
                .accessibilityElement(children: .combine)

                divider

                StarRatingView(rating: rating, size: 16, fillColor: .favoriteGoldText)

                divider

                HStack(spacing: AppSpacing.sm) {
                    Circle()
                        .fill(label == .none ? Color.clear : label.color)
                        .overlay(Circle().strokeBorder(label == .none ? Color.appMuted : Color.clear, lineWidth: 1))
                        .frame(width: 12, height: 12)
                    Text(label == .none ? "No Label" : label.title)
                        .foregroundStyle(label == .none ? Color.appMuted : label.textColor)
                }
                .accessibilityElement(children: .combine)

                divider

                Text(positionText)
                    .monospacedDigit()
                    .foregroundStyle(Color.appPrimaryText)
                    .accessibilityLabel("Item \(positionText.replacingOccurrences(of: " / ", with: " of "))")
            }
            .font(.appIcon(16, weight: .semibold))

            Text("P Pick   X Reject   U Unflag   0–5 Rate   6 Red · 7 Yellow · 8 Green · 9 Blue   ← → Move")
                .font(.appCaptionEmphasis)
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.md)
        .background(Color.appOverlaySurface, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).strokeBorder(Color.appOverlayStroke, lineWidth: 1))
        .shadow(color: Color.appShadowColor, radius: 14, y: 6)
        .padding(.horizontal, AppSpacing.xl)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Culling")
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.appOverlayDivider)
            .frame(width: 1, height: 18)
    }

    private func flashBadge(_ feedback: CullFeedback) -> some View {
        VStack(spacing: AppSpacing.sm) {
            flashGlyph(feedback.action)
                .font(.appIcon(44, weight: .bold))
            Text(feedback.action.feedbackTitle)
                .font(.appIcon(22, weight: .semibold))
                .foregroundStyle(Color.appPrimaryText)
        }
        .padding(.horizontal, AppSpacing.xxxl)
        .padding(.vertical, AppSpacing.xl)
        .background(Color.appOverlaySurface, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.xl).strokeBorder(Color.appOverlayStroke, lineWidth: 1))
        .shadow(color: Color.appShadowColor, radius: 18, y: 8)
    }

    @ViewBuilder
    private func flashGlyph(_ action: CullAction) -> some View {
        switch action {
        case let .flag(flag):
            Image(systemName: flag == .unflagged ? "flag.slash" : flag.systemImage)
                .foregroundStyle(flag == .unflagged ? Color.appMuted : flag.tint)
        case let .rating(stars):
            Image(systemName: stars == 0 ? "star.slash" : "star.fill")
                .foregroundStyle(stars == 0 ? Color.appMuted : Color.favoriteGoldText)
        case let .label(label):
            Image(systemName: label == .none ? "circle.slash" : "circle.fill")
                .foregroundStyle(label == .none ? Color.appMuted : label.color)
        }
    }
}
