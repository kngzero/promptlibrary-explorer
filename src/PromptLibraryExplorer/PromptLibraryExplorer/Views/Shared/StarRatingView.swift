import SwiftUI

struct StarRatingView: View {
    let rating: Int
    let maxRating: Int
    let size: CGFloat
    var fillColor: Color
    var onRate: ((Int) -> Void)?

    init(
        rating: Int,
        maxRating: Int = 5,
        size: CGFloat = 14,
        fillColor: Color = .appAccent,
        onRate: ((Int) -> Void)? = nil
    ) {
        self.rating = rating
        self.maxRating = maxRating
        self.size = size
        self.fillColor = fillColor
        self.onRate = onRate
    }

    var body: some View {
        HStack(spacing: size * 0.15) {
            ForEach(1...maxRating, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.appIcon(size, weight: .medium))
                    .foregroundStyle(star <= rating ? fillColor : Color.appMuted.opacity(0.4))
                    // Whole glyph box is clickable, not just the star's ink.
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let onRate {
                            onRate(star == rating ? 0 : star)
                        }
                    }
            }
        }
        // One adjustable element for VoiceOver instead of five unlabeled glyphs.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(accessibilityValueText)
        .accessibilityAdjustableAction { direction in
            guard let onRate else { return }
            switch direction {
            case .increment:
                if rating < maxRating { onRate(rating + 1) }
            case .decrement:
                if rating > 0 { onRate(rating - 1) }
            @unknown default:
                break
            }
        }
    }

    private var accessibilityValueText: String {
        switch rating {
        case 0: return "No stars"
        case 1: return "1 star"
        default: return "\(rating) stars"
        }
    }
}

/// Compact inline star rating for grid items (shows only if rated)
struct CompactStarBadge: View {
    let rating: Int

    var body: some View {
        if rating > 0 {
            HStack(spacing: AppSpacing.xxs) {
                Image(systemName: "star.fill")
                    .font(.appIcon(9, weight: .bold))
                Text("\(rating)")
                    .font(.appIcon(9, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, AppSpacing.xxs)
            .background(
                Capsule()
                    .fill(Color.appAccent.opacity(0.85))
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rating == 1 ? "Rated 1 star" : "Rated \(rating) stars")
        }
    }
}
