import Foundation

// Pure models behind View ▸ Start Slideshow: options, the play order
// (deterministic shuffle from a seed), what a slideshow shows, and the
// controls it offers (no deletion of any kind).

// MARK: - Options

enum SlideshowTransition: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case crossfade
    case slide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .crossfade: return "Crossfade"
        case .slide: return "Slide"
        }
    }
}

enum SlideshowBackground: String, CaseIterable, Identifiable, Codable, Sendable {
    case black
    case charcoal
    case gray
    case white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: return "Black"
        case .charcoal: return "Charcoal"
        case .gray: return "Gray"
        case .white: return "White"
        }
    }

    /// sRGB white level (the backgrounds are neutral).
    var whiteLevel: Double {
        switch self {
        case .black: return 0
        case .charcoal: return 0.11
        case .gray: return 0.5
        case .white: return 1
        }
    }

    /// Caption / control text on this background should be dark.
    var prefersDarkText: Bool { whiteLevel > 0.6 }
}

struct SlideshowOptions: Codable, Equatable, Sendable {
    static let intervalRange: ClosedRange<Double> = 2...30

    /// Seconds per image.
    var interval: Double = 5
    var transition: SlideshowTransition = .crossfade
    var shuffle = false
    var loop = true
    var showFileName = true
    var showPromptExcerpt = false
    var showRating = false
    /// Videos play inline and the slideshow moves on when they end.
    var includeVideos = true
    var background: SlideshowBackground = .black

    var clampedInterval: Double {
        min(max(interval, Self.intervalRange.lowerBound), Self.intervalRange.upperBound)
    }

    var showsCaption: Bool { showFileName || showPromptExcerpt || showRating }

    static let defaultsKey = "slideshow.options"

    static func load(from defaults: UserDefaults) -> SlideshowOptions {
        guard let data = defaults.data(forKey: defaultsKey),
              let options = try? JSONDecoder().decode(SlideshowOptions.self, from: data)
        else { return SlideshowOptions() }
        return options
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - Deterministic shuffle

/// SplitMix64: small, fast, and the same sequence for the same seed on every
/// run, so a shuffled order is reproducible (and testable).
struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Sequence

/// The play order over `count` slides. With shuffle the starting slide plays
/// first and the rest follow in a seeded random order; a loop replays the same
/// order.
struct SlideshowSequence: Equatable, Sendable {
    private(set) var order: [Int]
    /// Position in `order`.
    private(set) var position: Int = 0
    let loop: Bool

    init(count: Int, start: Int = 0, shuffle: Bool, loop: Bool, seed: UInt64) {
        self.loop = loop
        guard count > 0 else {
            order = []
            return
        }
        let first = min(max(start, 0), count - 1)
        if shuffle {
            var rest = Array(0..<count).filter { $0 != first }
            var generator = SeededGenerator(seed: seed)
            rest.shuffle(using: &generator)
            order = [first] + rest
        } else {
            order = Array(0..<count)
            position = first
        }
    }

    var isEmpty: Bool { order.isEmpty }
    var count: Int { order.count }

    /// Index (into the slides) of the current slide.
    var current: Int? { order.indices.contains(position) ? order[position] : nil }

    var isAtEnd: Bool { position >= order.count - 1 }
    var isAtStart: Bool { position <= 0 }

    /// Moves on. Returns the new slide, or nil at the end without a loop
    /// (the position stays on the last slide).
    @discardableResult
    mutating func advance() -> Int? {
        guard !order.isEmpty else { return nil }
        if position < order.count - 1 {
            position += 1
        } else if loop {
            position = 0
        } else {
            return nil
        }
        return current
    }

    /// Steps back. Wraps to the last slide only when looping.
    @discardableResult
    mutating func goBack() -> Int? {
        guard !order.isEmpty else { return nil }
        if position > 0 {
            position -= 1
        } else if loop {
            position = order.count - 1
        } else {
            return nil
        }
        return current
    }

    mutating func restart() { position = 0 }

    /// "3 / 20" (position in play order).
    var positionText: String {
        guard !order.isEmpty else { return "0 / 0" }
        return "\(position + 1) / \(order.count)"
    }
}

// MARK: - What plays

enum SlideshowEligibility {
    /// Still images and Mood / Story files (their rendered overview).
    static func isStill(_ name: String) -> Bool {
        FileHelpers.isImageFile(name) || FileHelpers.isArtOfficialDocumentFile(name)
    }

    static func isEligible(_ entry: FileEntry, includeVideos: Bool) -> Bool {
        guard !entry.isDirectory else { return false }
        if isStill(entry.name) { return true }
        return includeVideos && FileHelpers.isVideoFile(entry.name)
    }

    /// The slides and the one to start on. Two or more selected files play
    /// just the selection; otherwise the whole listing (folder, collection or
    /// virtual listing, with its filters — hidden rejects stay hidden — in
    /// listing order), starting at the selected file when there is one.
    static func slides(
        listing: [FileEntry],
        selectedPaths: [String],
        includeVideos: Bool
    ) -> (slides: [FileEntry], start: Int) {
        let selected = Set(selectedPaths)
        let eligible = listing.filter { isEligible($0, includeVideos: includeVideos) }
        if selected.count >= 2 {
            let chosen = eligible.filter { selected.contains($0.path) }
            if chosen.count >= 2 { return (chosen, 0) }
        }
        let start = selectedPaths.first.flatMap { path in eligible.firstIndex { $0.path == path } } ?? 0
        return (eligible, start)
    }

    /// The prompt excerpt shown in a caption: one line, at most `limit` characters.
    static func promptExcerpt(_ prompt: String, limit: Int = 160) -> String {
        let flattened = prompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        let cut = flattened.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }
}

// MARK: - Controls

/// What the slideshow's control bar offers. No deletion of any kind.
enum SlideshowControlAction: String, CaseIterable, Identifiable, Sendable {
    case previous
    case playPause
    case next
    case options
    case close

    var id: String { rawValue }

    var title: String {
        switch self {
        case .previous: return "Previous"
        case .playPause: return "Play / Pause"
        case .next: return "Next"
        case .options: return "Options"
        case .close: return "End Slideshow"
        }
    }
}

/// Keys the slideshow window owns (its own key handling; the main window's
/// monitors stand down while it is key).
enum SlideshowKeyAction: Equatable, Sendable {
    case previous
    case next
    case playPause
    case close

    static func action(keyCode: UInt16, hasModifiers: Bool) -> SlideshowKeyAction? {
        guard !hasModifiers else { return nil }
        switch keyCode {
        case KeyCode.leftArrow.rawValue: return .previous
        case KeyCode.rightArrow.rawValue: return .next
        case KeyCode.space.rawValue: return .playPause
        case KeyCode.escape.rawValue: return .close
        default: return nil
        }
    }
}
