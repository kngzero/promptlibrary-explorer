import SwiftUI

/// Generation Info in the details panel and the lightbox: Model and Aspect
/// Ratio side by side, the same height and top-aligned, with Timestamp across
/// both columns below. One spacing for every gap.
struct GenerationInfoGrid: View {
    let info: GenerationInfo
    /// The image's pixel size; its aspect ratio wins over the metadata's.
    let pixelSize: (width: Int, height: Int)?

    var body: some View {
        Grid(horizontalSpacing: AppSpacing.md, verticalSpacing: AppSpacing.md) {
            GridRow {
                cell(title: "Model", value: info.model)
                cell(title: "Aspect Ratio", value: aspectRatio)
            }
            if !info.timestamp.isEmpty {
                GridRow {
                    cell(title: "Timestamp", value: Self.formatTimestamp(info.timestamp))
                        .gridCellColumns(2)
                }
            }
        }
    }

    private var aspectRatio: String {
        if let pixelSize, let ratio = AspectRatioLabel.label(width: pixelSize.width, height: pixelSize.height) {
            return ratio
        }
        return info.aspectRatio.rawValue
    }

    private func cell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(title)
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)
            Text(value)
                .font(.appIcon(13, weight: .medium))
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        // Fill the row's height too, so cells side by side match.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.md)
    }

    /// ISO 8601 (with or without fractional seconds) as "2026-06-25, 5:06:40 PM";
    /// anything else as written.
    static func formatTimestamp(_ timestamp: String) -> String {
        let iso = ISO8601DateFormatter()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd, h:mm:ss a"
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: timestamp) { return formatter.string(from: date) }
        }
        return timestamp
    }
}

extension FileMetadata {
    var pixelSize: (width: Int, height: Int)? {
        guard let width, let height else { return nil }
        return (width, height)
    }
}

/// An aspect ratio read from pixel dimensions: the common ratio within 1 %
/// ("9:16" for 768 × 1376), else the reduced ratio when it stays small
/// ("7:5"), else "1.79:1".
enum AspectRatioLabel {
    private static let common: [(Int, Int)] = [
        (1, 1), (5, 4), (4, 3), (3, 2), (16, 10), (16, 9), (2, 1), (21, 9), (3, 1),
    ]

    static func label(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        let value = Double(width) / Double(height)
        for (a, b) in common {
            for (w, h) in a == b ? [(a, b)] : [(a, b), (b, a)] where abs(value / (Double(w) / Double(h)) - 1) <= 0.01 {
                return "\(w):\(h)"
            }
        }
        let divisor = gcd(width, height)
        let w = width / divisor, h = height / divisor
        if max(w, h) <= 32 { return "\(w):\(h)" }
        return value >= 1
            ? String(format: "%.2f:1", value)
            : String(format: "1:%.2f", 1 / value)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}
