import SwiftUI

struct TitlebarIdentityView: View {
    private let logoHeight: CGFloat = 16

    var body: some View {
        HStack(spacing: 10) {
            ArtOfficialLogoMark()
                .fill(Color.appAccent)
                .frame(width: logoHeight * ArtOfficialLogoMark.aspectRatio, height: logoHeight)
                .accessibilityHidden(true)

            Text(appName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
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

private struct ArtOfficialLogoMark: Shape {
    static let sourceBounds = CGRect(x: 199.67, y: 399.67, width: 800, height: 400)
    static let aspectRatio = sourceBounds.width / sourceBounds.height

    func path(in rect: CGRect) -> Path {
        let bounds = Self.sourceBounds
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let xOffset = rect.minX + ((rect.width - (bounds.width * scale)) / 2)
        let yOffset = rect.minY + ((rect.height - (bounds.height * scale)) / 2)
        let transform = CGAffineTransform(translationX: xOffset, y: yOffset)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.minX, y: -bounds.minY)

        return Self.logoPath.applying(transform)
    }

    // Uses the white mark from ../logo.svg only, excluding the black artboard rectangle.
    private static var logoPath: Path {
        var path = Path()

        path.addEllipse(in: CGRect(x: 599.67, y: 399.67, width: 400, height: 400))

        path.move(to: CGPoint(x: 379.67, y: 399.67))
        path.addCurve(
            to: CGPoint(x: 199.67, y: 579.67),
            control1: CGPoint(x: 280.26, y: 399.67),
            control2: CGPoint(x: 199.67, y: 480.26)
        )
        path.addLine(to: CGPoint(x: 199.67, y: 799.67))
        path.addLine(to: CGPoint(x: 559.67, y: 799.67))
        path.addLine(to: CGPoint(x: 559.67, y: 579.67))
        path.addCurve(
            to: CGPoint(x: 379.67, y: 399.67),
            control1: CGPoint(x: 559.67, y: 480.26),
            control2: CGPoint(x: 479.08, y: 399.67)
        )
        path.closeSubpath()

        return path
    }
}
