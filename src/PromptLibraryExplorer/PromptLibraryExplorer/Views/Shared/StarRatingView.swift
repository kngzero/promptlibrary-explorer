import SwiftUI

struct StarRatingView: View {
    let rating: Int
    let maxRating: Int
    let size: CGFloat
    var onRate: ((Int) -> Void)?

    init(rating: Int, maxRating: Int = 5, size: CGFloat = 14, onRate: ((Int) -> Void)? = nil) {
        self.rating = rating
        self.maxRating = maxRating
        self.size = size
        self.onRate = onRate
    }

    var body: some View {
        HStack(spacing: size * 0.15) {
            ForEach(1...maxRating, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(star <= rating ? Color.appAccent : Color.appMuted.opacity(0.4))
                    .onTapGesture {
                        if let onRate {
                            onRate(star == rating ? 0 : star)
                        }
                    }
            }
        }
    }
}

/// Compact inline star rating for grid items (shows only if rated)
struct CompactStarBadge: View {
    let rating: Int

    var body: some View {
        if rating > 0 {
            HStack(spacing: 2) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("\(rating)")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.appAccent.opacity(0.85))
            )
        }
    }
}
