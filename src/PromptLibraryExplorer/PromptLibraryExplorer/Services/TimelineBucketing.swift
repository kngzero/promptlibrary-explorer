import Foundation

// MARK: - Timeline model: items, zoom levels, buckets
//
// Buckets are wall-clock days: a captured date with its own UTC offset (EXIF
// OffsetTime, QuickTime creation date) is bucketed in that offset, so a photo
// taken at 23:30 in Tokyo stays on its day wherever the Mac is. File dates
// (created / modified) are bucketed in the calendar's time zone.

/// One file on the timeline / map.
struct TimelineItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let date: Date
    let source: CaptureDateSource
    /// Seconds east of GMT of the capture's wall-clock time (captured dates only).
    let utcOffset: Int?
    let origin: CaptureDateOrigin?
    let coordinate: GeoCoordinate?

    init(path: String, date: Date, source: CaptureDateSource, utcOffset: Int? = nil,
         origin: CaptureDateOrigin? = nil, coordinate: GeoCoordinate? = nil)
    {
        self.path = path
        self.date = date
        self.source = source
        self.utcOffset = utcOffset
        self.origin = origin
        self.coordinate = coordinate
    }

    init(path: String, resolved: ResolvedCaptureDate, coordinate: GeoCoordinate?) {
        self.init(path: path, date: resolved.date, source: resolved.source,
                  utcOffset: resolved.utcOffset, origin: resolved.origin, coordinate: coordinate)
    }

    var name: String { (path as NSString).lastPathComponent }

    /// "Captured (EXIF date taken)", "Created", "Modified".
    var sourceDescription: String {
        guard source == .captured, let origin else { return source.title }
        return "\(source.title) (\(origin.title))"
    }
}

enum TimelineZoom: String, CaseIterable, Identifiable, Sendable {
    case year
    case month
    case day

    var id: String { rawValue }

    var title: String {
        switch self {
        case .year: return "Years"
        case .month: return "Months"
        case .day: return "Days"
        }
    }

    /// Thumbnail edge (points) for the zoom: denser when zoomed out.
    var thumbnailSize: Double {
        switch self {
        case .year: return 44
        case .month: return 64
        case .day: return 104
        }
    }

    var zoomedIn: TimelineZoom? {
        switch self {
        case .year: return .month
        case .month: return .day
        case .day: return nil
        }
    }

    var zoomedOut: TimelineZoom? {
        switch self {
        case .year: return nil
        case .month: return .year
        case .day: return .month
        }
    }
}

/// A wall-clock calendar day.
struct TimelineDay: Hashable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    static func < (lhs: TimelineDay, rhs: TimelineDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

struct TimelineSection: Identifiable, Sendable, Equatable {
    /// "y2024", "m2024-03" or "d2024-03-12".
    let id: String
    let zoom: TimelineZoom
    let year: Int
    /// nil for year sections.
    let month: Int?
    /// nil for year and month sections.
    let day: Int?
    /// Newest first.
    let items: [TimelineItem]

    /// Items whose date is an embedded capture date.
    var capturedCount: Int { items.reduce(0) { $0 + ($1.source == .captured ? 1 : 0) } }
}

/// One month bar of the density scrubber.
struct TimelineMonthBin: Identifiable, Sendable, Hashable {
    var id: String { String(format: "%04d-%02d", year, month) }
    let year: Int
    let month: Int
    let count: Int
}

enum TimelineBucketer {
    /// The item's wall-clock day: in its own UTC offset when it has one, else in
    /// `calendar`'s time zone.
    static func day(of item: TimelineItem, calendar: Calendar) -> TimelineDay {
        var cache: [Int: Calendar] = [:]
        return day(of: item, calendar: calendar, cache: &cache)
    }

    private static func day(of item: TimelineItem, calendar: Calendar, cache: inout [Int: Calendar]) -> TimelineDay {
        var effective = calendar
        if let offset = item.utcOffset {
            if let cached = cache[offset] {
                effective = cached
            } else if let zone = TimeZone(secondsFromGMT: offset) {
                effective.timeZone = zone
                cache[offset] = effective
            }
        }
        let components = effective.dateComponents([.year, .month, .day], from: item.date)
        return TimelineDay(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    static func sectionID(year: Int, month: Int?, day: Int?, zoom: TimelineZoom) -> String {
        switch zoom {
        case .year: return String(format: "y%04d", year)
        case .month: return String(format: "m%04d-%02d", year, month ?? 1)
        case .day: return String(format: "d%04d-%02d-%02d", year, month ?? 1, day ?? 1)
        }
    }

    /// Sections newest first; items in each newest first (ties by path).
    static func sections(for items: [TimelineItem], zoom: TimelineZoom, calendar: Calendar) -> [TimelineSection] {
        var cache: [Int: Calendar] = [:]
        var buckets: [TimelineDay: [TimelineItem]] = [:]
        for item in items {
            let day = day(of: item, calendar: calendar, cache: &cache)
            let key: TimelineDay
            switch zoom {
            case .year: key = TimelineDay(year: day.year, month: 0, day: 0)
            case .month: key = TimelineDay(year: day.year, month: day.month, day: 0)
            case .day: key = day
            }
            buckets[key, default: []].append(item)
        }
        return buckets.keys.sorted(by: >).map { key in
            let members = buckets[key]!.sorted { lhs, rhs in
                lhs.date != rhs.date ? lhs.date > rhs.date : lhs.path < rhs.path
            }
            let month: Int? = zoom == .year ? nil : key.month
            let day: Int? = zoom == .day ? key.day : nil
            return TimelineSection(
                id: sectionID(year: key.year, month: month, day: day, zoom: zoom),
                zoom: zoom, year: key.year, month: month, day: day, items: members
            )
        }
    }

    /// One bar per month from the newest month to the oldest (empty months
    /// included, so gaps show), newest first. Very long spans (over 100 years:
    /// bad dates) keep only the non-empty months.
    static func monthBins(for items: [TimelineItem], calendar: Calendar) -> [TimelineMonthBin] {
        var cache: [Int: Calendar] = [:]
        var counts: [Int: Int] = [:] // year * 12 + (month - 1)
        for item in items {
            let day = day(of: item, calendar: calendar, cache: &cache)
            counts[day.year * 12 + day.month - 1, default: 0] += 1
        }
        guard let newest = counts.keys.max(), let oldest = counts.keys.min() else { return [] }
        let indices: [Int] = newest - oldest > 1200
            ? counts.keys.sorted(by: >)
            : Array(stride(from: newest, through: oldest, by: -1))
        return indices.map { index in
            TimelineMonthBin(year: index / 12, month: index % 12 + 1, count: counts[index] ?? 0)
        }
    }

    /// The section a month bin jumps to at `zoom`: the month's own section (or
    /// its year), else the nearest older section that exists.
    static func sectionID(for bin: TimelineMonthBin, in sections: [TimelineSection]) -> String? {
        guard !sections.isEmpty else { return nil }
        let zoom = sections[0].zoom
        func key(_ section: TimelineSection) -> Int { section.year * 12 + (section.month ?? 12) - 1 }
        let target = zoom == .year ? bin.year * 12 + 11 : bin.year * 12 + bin.month - 1
        // Sections are newest first: the first at or before the target month.
        if let match = sections.first(where: { key($0) <= target }) { return match.id }
        return sections.last?.id
    }

    /// Items of the same wall-clock day as `item`, newest first.
    static func dayItems(containing item: TimelineItem, in items: [TimelineItem], calendar: Calendar) -> [TimelineItem] {
        var cache: [Int: Calendar] = [:]
        let target = day(of: item, calendar: calendar, cache: &cache)
        return items.filter { day(of: $0, calendar: calendar, cache: &cache) == target }
            .sorted { lhs, rhs in lhs.date != rhs.date ? lhs.date > rhs.date : lhs.path < rhs.path }
    }

    // MARK: Titles

    /// "2024", "March 2024", "Tuesday 12 March 2024" (localized).
    static func title(for section: TimelineSection, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: section.year, month: section.month ?? 1, day: section.day ?? 1, hour: 12))
            ?? Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        switch section.zoom {
        case .year: formatter.setLocalizedDateFormatFromTemplate("y")
        case .month: formatter.setLocalizedDateFormatFromTemplate("MMMMy")
        case .day: formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMMy")
        }
        return formatter.string(from: date)
    }

    /// "Mar 2024" for a scrubber tooltip.
    static func title(for bin: TimelineMonthBin, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: bin.year, month: bin.month, day: 1, hour: 12)) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMy")
        return formatter.string(from: date)
    }
}
