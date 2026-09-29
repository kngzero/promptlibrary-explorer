import SwiftUI

struct TitlebarIdentityView: View {
    private let logoHeight: CGFloat = 16

    var body: some View {
        HStack(spacing: 10) {
            ExplorerGlyph()
                .frame(width: logoHeight, height: logoHeight)
                .accessibilityHidden(true)

            Text(appName)
                .font(.appTitle)
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, AppSpacing.md)
    }

    private var appName: String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty
        {
            return displayName
        }

        if let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.isEmpty
        {
            return bundleName
        }

        return "PromptLibraryExplorer"
    }
}

/// The Explorer glyph from the suite branding package: a 2 × 2 grid on a 400 × 400 box, one
/// cell per app it opens (Mood arch, Story bubble, images circle, Stack S), each in its app colour.
private struct ExplorerGlyph: View {
    var body: some View {
        ZStack {
            ExplorerGlyphCell(kind: .mood).fill(Color.brandMood)
            ExplorerGlyphCell(kind: .story).fill(Color.brandStory)
            ExplorerGlyphCell(kind: .images).fill(Color.brandImages)
            ExplorerGlyphCell(kind: .stack).fill(Color.brandStack)
        }
    }
}

private struct ExplorerGlyphCell: Shape {
    enum Kind { case mood, story, images, stack }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 400
        let transform = CGAffineTransform(
            translationX: rect.midX - 200 * scale,
            y: rect.midY - 200 * scale
        ).scaledBy(x: scale, y: scale)
        return sourcePath.applying(transform)
    }

    /// Native 400-unit geometry (explorer-glyph-*.svg). Every arc runs clockwise on screen.
    private var sourcePath: Path {
        var path = Path()
        func line(_ x: CGFloat, _ y: CGFloat) { path.addLine(to: CGPoint(x: x, y: y)) }
        func arc(center: CGPoint, radius: CGFloat, to x: CGFloat, _ y: CGFloat) {
            guard let from = path.currentPoint else { return }
            let start = atan2(from.y - center.y, from.x - center.x)
            var end = atan2(y - center.y, x - center.x)
            if end < start { end += 2 * .pi }
            path.addArc(center: center, radius: radius, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        }

        switch kind {
        case .mood:
            path.move(to: CGPoint(x: 9, y: 180))
            line(9, 81)
            arc(center: CGPoint(x: 90, y: 81), radius: 81, to: 171, 81)
            line(171, 180)
        case .story:
            let c = CGPoint(x: 310, y: 90)
            path.move(to: CGPoint(x: 310, y: 0))
            arc(center: c, radius: 90, to: 400, 90)
            arc(center: c, radius: 90, to: 310, 180)
            line(220, 180)
            line(220, 90)
            arc(center: c, radius: 90, to: 310, 0)
        case .images:
            path.addEllipse(in: CGRect(x: 0, y: 220, width: 180, height: 180))
        case .stack:
            // Three bars in a 180 cell whose top-left and bottom-right corners are r 90.
            let c = CGPoint(x: 310, y: 310)
            path.move(to: CGPoint(x: 310, y: 220))
            line(400, 220)
            line(400, 265)
            line(232.058, 265)
            arc(center: c, radius: 90, to: 310, 220)
            path.closeSubpath()
            path.move(to: CGPoint(x: 222.858, y: 287.5))
            line(400, 287.5)
            line(400, 310)
            arc(center: c, radius: 90, to: 397.142, 332.5)
            line(220, 332.5)
            line(220, 310)
            arc(center: c, radius: 90, to: 222.858, 287.5)
            path.closeSubpath()
            path.move(to: CGPoint(x: 220, y: 355))
            line(387.942, 355)
            arc(center: c, radius: 90, to: 310, 400)
            line(220, 400)
        }
        path.closeSubpath()
        return path
    }
}
