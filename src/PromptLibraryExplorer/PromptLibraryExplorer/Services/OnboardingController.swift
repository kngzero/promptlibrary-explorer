import Foundation
import Observation

// MARK: - Welcome tour pages

/// The welcome tour, in order. Short and skippable: one idea per page.
enum WelcomeTourPage: Int, CaseIterable, Identifiable, Sendable {
    case welcome
    case openLibrary
    case browse
    case cull
    case find
    case organise
    case data

    var id: Int { rawValue }

    var headline: String {
        switch self {
        case .welcome: return "A library that reads your prompts"
        case .openLibrary: return "Start with a folder"
        case .browse: return "Browse, then look closer"
        case .cull: return "Cull at the speed of your keyboard"
        case .find: return "Find anything"
        case .organise: return "Organise without moving files"
        case .data: return "Your data is safe"
        }
    }

    var body: String {
        switch self {
        case .welcome:
            return "PromptLibrary Explorer browses AI images, video and audio, and reads the prompts, seeds and settings embedded in them — from ComfyUI, A1111, Midjourney and Art Official files."
        case .openLibrary:
            return "Choose File ▸ Open Folder… (⌘O) or drop a folder on the window. Your files stay where they are; the sidebar shows the folder tree, favourites, collections and smart folders."
        case .browse:
            return "Select a file and the details panel shows its prompt, negative prompt and parameters. ⇧⌘C copies the prompt; Copy Prompt As… gives Midjourney, Stable Diffusion or JSON. Space opens the lightbox."
        case .cull:
            return "P picks, X rejects, U unflags, 0–5 set stars and 6–9 set colour labels — in the grid or the lightbox. Culling Mode (Cull menu) adds a culling bar and auto-advance."
        case .find:
            return "⌘F searches the folder by name, prompt or text in the image; ⇧⌘F searches the whole library. ⌘K is the command palette. Similar Images, More Like This (M) and colour search find things by look."
        case .organise:
            return "Collections (grouped into sets) and smart folders gather files from anywhere. Tags, version stacks and the ingest Inbox for watched folders keep new renders in order."
        case .data:
            return "Ratings, tags and collections are backed up daily, written to a sync file in your library for your other Macs, and mirrored to Finder tags. Settings ▸ Data has every control."
        }
    }

    /// Hero symbol for the illustration.
    var symbol: String {
        switch self {
        case .welcome: return "sparkles.rectangle.stack"
        case .openLibrary: return "folder.badge.plus"
        case .browse: return "sidebar.right"
        case .cull: return "flag.checkered"
        case .find: return "magnifyingglass"
        case .organise: return "rectangle.stack"
        case .data: return "externaldrive.badge.checkmark"
        }
    }

    /// Supporting symbols orbiting the hero.
    var accessorySymbols: [String] {
        switch self {
        case .welcome: return ["photo", "film", "waveform", "text.quote"]
        case .openLibrary: return ["arrow.down.circle", "folder", "sidebar.left"]
        case .browse: return ["square.grid.2x2", "text.quote", "doc.on.doc"]
        case .cull: return ["star.fill", "xmark.circle", "tag"]
        case .find: return ["command", "square.on.square", "paintpalette"]
        case .organise: return ["folder.badge.gearshape", "square.stack.3d.up", "tray.and.arrow.down"]
        case .data: return ["clock.arrow.circlepath", "arrow.triangle.2.circlepath", "tag"]
        }
    }

    /// Keycaps shown under the illustration, where keys are the point.
    var keycaps: [String] {
        switch self {
        case .welcome: return []
        case .openLibrary: return ["⌘O"]
        case .browse: return ["⇧⌘C", "Space"]
        case .cull: return ["P", "X", "U", "0–5", "6–9"]
        case .find: return ["⌘F", "⇧⌘F", "⌘K", "M"]
        case .organise: return []
        case .data: return []
        }
    }

    /// "Try it": opens the feature (after the tour closes).
    var tryIt: HelpCommand? {
        switch self {
        case .welcome: return nil
        case .openLibrary: return .openFolder
        case .browse: return nil
        case .cull: return .cullingMode
        case .find: return .commandPalette
        case .organise: return .newSmartFolder
        case .data: return .dataSettings
        }
    }
}

/// Paging state for the tour (pure, so it can be tested).
struct WelcomeTourState: Equatable, Sendable {
    enum Key: Equatable, Sendable { case left, right, returnKey, escape }
    enum Outcome: Equatable, Sendable { case moved, finish, skip, ignored }

    let pageCount: Int
    private(set) var index = 0

    init(pageCount: Int = WelcomeTourPage.allCases.count, index: Int = 0) {
        self.pageCount = max(1, pageCount)
        self.index = min(max(0, index), self.pageCount - 1)
    }

    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == pageCount - 1 }
    var page: WelcomeTourPage? { WelcomeTourPage(rawValue: index) }

    /// false at the last page.
    @discardableResult
    mutating func next() -> Bool {
        guard !isLast else { return false }
        index += 1
        return true
    }

    /// false at the first page.
    @discardableResult
    mutating func previous() -> Bool {
        guard !isFirst else { return false }
        index -= 1
        return true
    }

    mutating func go(to page: Int) {
        index = min(max(0, page), pageCount - 1)
    }

    /// ← / → page, Return advances (finishes on the last page), Esc skips.
    mutating func handle(_ key: Key) -> Outcome {
        switch key {
        case .left: return previous() ? .moved : .ignored
        case .right: return next() ? .moved : .ignored
        case .returnKey: return next() ? .moved : .finish
        case .escape: return .skip
        }
    }
}

// MARK: - Controller

/// Welcome tour presentation and Help routing (which entry to open at). Tips live
/// in `OnboardingTipsController`.
@MainActor @Observable
final class OnboardingController {
    static let shared = OnboardingController()

    static let tourSeenKey = "onboarding.tour.seen"

    /// The welcome tour sheet is up.
    var isTourPresented = false
    /// Help opens scrolled to (and highlighting) this entry or section.
    var helpFocus: HelpFocus?
    /// Run once the tour or Help sheet has gone ("Try it", "Show Me").
    @ObservationIgnored var pendingCommand: HelpCommand?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasSeenTour: Bool {
        get { defaults.bool(forKey: Self.tourSeenKey) }
        set { defaults.set(newValue, forKey: Self.tourSeenKey) }
    }

    /// First launch only. Returns true when the tour was presented.
    @discardableResult
    func presentTourIfFirstLaunch() -> Bool {
        guard !hasSeenTour, !isTourPresented else { return false }
        presentTour()
        return true
    }

    /// Help ▸ Welcome Tour…
    func presentTour() {
        hasSeenTour = true
        isTourPresented = true
    }

    /// Closes the tour, then runs `command` (if any) once the sheet is gone.
    func finishTour(running command: HelpCommand? = nil) {
        pendingCommand = command
        isTourPresented = false
    }

    /// Takes the command queued by a sheet that just closed.
    func takePendingCommand() -> HelpCommand? {
        defer { pendingCommand = nil }
        return pendingCommand
    }
}

/// Where Help opens.
enum HelpFocus: Equatable, Sendable {
    case entry(String)
    case section(HelpSectionID)
}
