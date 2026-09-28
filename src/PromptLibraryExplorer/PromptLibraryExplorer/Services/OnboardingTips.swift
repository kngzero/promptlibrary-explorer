import Foundation
import Observation

// MARK: - Tips

/// A one-time contextual tip. Each appears at most once (ever), at the moment its
/// feature becomes relevant, and never while something modal is up or the user is
/// typing. Views/Onboarding draws them; `OnboardingTipsController` decides when.
enum OnboardingTip: String, CaseIterable, Identifiable, Codable, Sendable {
    /// First time a file with an embedded prompt is selected.
    case promptSelected
    /// First time the lightbox opens.
    case lightboxOpened
    /// First multi-selection of 2–4 comparable files.
    case compareSelection
    /// First listing with more than 50 images.
    case largeFolder
    /// First collection created.
    case firstCollection
    /// First time library indexing finishes.
    case indexingFinished
    /// First time a video is selected in the browser (hover scrubbing, trim).
    case videoSelected
    /// First export that finishes.
    case firstExport

    var id: String { rawValue }

    /// Where the card sits (see `OnboardingTipPlacement`).
    var placement: OnboardingTipPlacement {
        switch self {
        case .promptSelected: return .besideDetailsPanel
        case .lightboxOpened: return .lightboxTopTrailing
        case .largeFolder, .indexingFinished, .firstExport: return .contentTopTrailing
        case .compareSelection, .firstCollection, .videoSelected: return .contentBottomLeading
        }
    }

    var symbol: String {
        switch self {
        case .promptSelected: return "text.quote"
        case .lightboxOpened: return "flag.checkered"
        case .compareSelection: return "rectangle.split.2x1"
        case .largeFolder: return "square.on.square"
        case .firstCollection: return "rectangle.stack"
        case .indexingFinished: return "magnifyingglass"
        case .videoSelected: return "film"
        case .firstExport: return "square.and.arrow.up.on.square"
        }
    }

    var title: String {
        switch self {
        case .promptSelected: return "This file carries its prompt"
        case .lightboxOpened: return "Cull right here"
        case .compareSelection: return "Compare them side by side"
        case .largeFolder: return "Lots of variations?"
        case .firstCollection: return "Collections can do more"
        case .indexingFinished: return "Your library is indexed"
        case .videoSelected: return "Scrub and trim videos"
        case .firstExport: return "Make it a preset"
        }
    }

    var message: String {
        switch self {
        case .promptSelected:
            return "The details panel shows the prompt and settings. ⇧⌘C copies it; Edit ▸ Copy Prompt As… gives Midjourney, Stable Diffusion or JSON, and Prompt Tools opens the Builder and Lineage."
        case .lightboxOpened:
            return "P pick · X reject · U unflag · 0–5 stars · 6–9 colour labels. The loupe button at the top looks closer (View ▸ Histogram shows levels in the details panel); M finds more like this."
        case .compareSelection:
            return "View ▸ Compare Images shows 2–4 files with synced zoom and an A/B wipe. With two selected, ⌘D compares their prompts."
        case .largeFolder:
            return "Library ▸ Similar Images groups near-duplicates (nothing is ever marked for deletion), and View ▸ Stack Variants tucks re-rolls behind one cover."
        case .firstCollection:
            return "Group collections into sets from the sidebar's + menu. A collection's context menu sends it to Mood or Story, or exports it."
        case .indexingFinished:
            return "Find in Library (⇧⌘F) searches every prompt in the library, and Spotlight finds your files by prompt, tag and model."
        case .videoSelected:
            return "Move the pointer across a video's tile to scrub it. Trim & Export Clip… (File menu, context menu, lightbox) saves a clip or GIF; the original is never changed."
        case .firstExport:
            return "Save format, size, metadata and watermark as a preset in Settings ▸ Export. Export for Sharing strips prompts, seeds and workflows before you post."
        }
    }

    /// Optional one-click entry point shown on the card.
    var action: HelpCommand? {
        switch self {
        case .promptSelected: return .promptBuilder
        case .lightboxOpened: return .cullingMode
        case .compareSelection: return .compareImages
        case .largeFolder: return .similarImages
        case .firstCollection: return nil
        case .indexingFinished: return .findInLibrary
        case .videoSelected: return .trimClip
        case .firstExport: return .exportSettings
        }
    }

    /// The Help entry that explains the feature in full.
    var helpEntryID: String {
        switch self {
        case .promptSelected: return "prompts-copy"
        case .lightboxOpened: return "culling"
        case .compareSelection: return "viewing-tools"
        case .largeFolder: return "visual-search"
        case .firstCollection: return "collections"
        case .indexingFinished: return "library-search"
        case .videoSelected: return "video-audio-tools"
        case .firstExport: return "export"
        }
    }
}

/// Where a tip card is drawn in the main window. Anchored to the browser's columns
/// (their sizes are known) rather than to individual controls, which live in
/// separate hosting views.
enum OnboardingTipPlacement: Equatable, Sendable {
    /// Bottom-leading corner of the content column (the default).
    case contentBottomLeading
    /// Top-trailing corner of the content column, under the toolbar.
    case contentTopTrailing
    /// Trailing edge of the content column, pointing at the details panel.
    case besideDetailsPanel
    /// Top-trailing corner of the lightbox, under its header buttons.
    case lightboxTopTrailing
}

// MARK: - Scheduling rules (pure)

/// What the app is doing right now, as far as tips are concerned.
struct TipConditions: Equatable, Sendable {
    /// A sheet, alert, save panel, the command palette or the welcome tour is up.
    var isModalOpen = false
    /// A text field is being edited.
    var isTyping = false
}

/// Why a tip can't show right now.
enum TipBlockReason: Equatable, Sendable {
    case tipsDisabled
    case alreadyShown
    case anotherTipShowing
    case rateLimited
    case modalOpen
    case typing
    case notRelevant
}

/// The scheduling rules, free of timers, persistence and UI so they can be tested:
/// once-only per tip, one tip at a time, at most one per `minimumInterval`, never
/// during modals or typing, and a global off switch.
struct TipScheduler: Equatable, Sendable {
    /// At most one tip per this many seconds ("one per session minute").
    static let minimumInterval: TimeInterval = 60
    /// A requested tip that couldn't show waits this long for a better moment.
    static let pendingLifetime: TimeInterval = 120

    struct Pending: Equatable, Sendable {
        var tip: OnboardingTip
        var requestedAt: Date
    }

    var tipsEnabled = true
    /// Tips shown (or dismissed) at some point: never shown again.
    var shown: Set<OnboardingTip> = []
    private(set) var activeTip: OnboardingTip?
    private(set) var lastShownAt: Date?
    private(set) var pending: [Pending] = []

    init(tipsEnabled: Bool = true, shown: Set<OnboardingTip> = []) {
        self.tipsEnabled = tipsEnabled
        self.shown = shown
    }

    /// nil when `tip` may show now.
    func blockReason(
        for tip: OnboardingTip,
        now: Date,
        conditions: TipConditions,
        isRelevant: Bool = true
    ) -> TipBlockReason? {
        if !tipsEnabled { return .tipsDisabled }
        if shown.contains(tip) { return .alreadyShown }
        if activeTip != nil { return .anotherTipShowing }
        if conditions.isModalOpen { return .modalOpen }
        if conditions.isTyping { return .typing }
        if let lastShownAt, now.timeIntervalSince(lastShownAt) < Self.minimumInterval { return .rateLimited }
        if !isRelevant { return .notRelevant }
        return nil
    }

    /// The moment for `tip` has come. Returns true if it was queued (it may show on
    /// the next `nextTip`); false when it can never show (off, or already shown).
    @discardableResult
    mutating func request(_ tip: OnboardingTip, now: Date) -> Bool {
        guard tipsEnabled, !shown.contains(tip), activeTip != tip else { return false }
        if let index = pending.firstIndex(where: { $0.tip == tip }) {
            pending[index].requestedAt = now
        } else {
            pending.append(Pending(tip: tip, requestedAt: now))
        }
        return true
    }

    /// A tip's moment has passed (the lightbox closed, the selection changed).
    mutating func withdraw(_ tip: OnboardingTip) {
        pending.removeAll { $0.tip == tip }
    }

    /// Picks the first pending tip that may show now, makes it active and marks it
    /// shown. Expired and no-longer-possible requests are dropped.
    mutating func nextTip(
        now: Date,
        conditions: TipConditions,
        isRelevant: (OnboardingTip) -> Bool = { _ in true }
    ) -> OnboardingTip? {
        pending.removeAll { entry in
            now.timeIntervalSince(entry.requestedAt) > Self.pendingLifetime
                || shown.contains(entry.tip)
                || !tipsEnabled
        }
        for entry in pending {
            let relevant = isRelevant(entry.tip)
            guard blockReason(for: entry.tip, now: now, conditions: conditions, isRelevant: relevant) == nil else {
                continue
            }
            show(entry.tip, now: now)
            return entry.tip
        }
        return nil
    }

    /// Shows `tip` directly (used by `nextTip`).
    mutating func show(_ tip: OnboardingTip, now: Date) {
        activeTip = tip
        lastShownAt = now
        shown.insert(tip)
        pending.removeAll { $0.tip == tip }
    }

    /// The active tip went away (Got it, closed, or no longer relevant).
    mutating func dismissActive() {
        activeTip = nil
    }

    /// "Don't Show Tips": everything off, nothing pending.
    mutating func disableAll() {
        tipsEnabled = false
        activeTip = nil
        pending.removeAll()
    }

    /// Help ▸ Reset Tips: every tip can show again (and tips are turned on).
    mutating func reset() {
        shown.removeAll()
        pending.removeAll()
        activeTip = nil
        lastShownAt = nil
        tipsEnabled = true
    }
}

// MARK: - Controller

/// Persists tip state and drives `TipScheduler` on the main actor. Views request
/// tips when their moment comes; a short poll retries tips that had to wait.
@MainActor @Observable
final class OnboardingTipsController {
    static let shared = OnboardingTipsController()

    static let enabledKey = "onboarding.tips.enabled"
    static let shownKey = "onboarding.tips.shown"
    /// How often a waiting tip is re-checked.
    static let pollInterval: Duration = .seconds(2)

    private(set) var scheduler: TipScheduler

    var activeTip: OnboardingTip? { scheduler.activeTip }

    /// Global switch (Settings ▸ Appearance ▸ Tips, Help ▸ Show Tips).
    var tipsEnabled: Bool {
        get { scheduler.tipsEnabled }
        set {
            guard newValue != scheduler.tipsEnabled else { return }
            if newValue {
                scheduler.tipsEnabled = true
            } else {
                scheduler.disableAll()
            }
            persist()
        }
    }

    /// Supplied by the tip layer: the current modal / typing state, and whether a
    /// tip still makes sense (the lightbox tip only while the lightbox is open…).
    @ObservationIgnored var conditionsProvider: () -> TipConditions = { TipConditions() }
    @ObservationIgnored var relevance: (OnboardingTip) -> Bool = { _ in true }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let pollsAutomatically: Bool
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = { Date() }, pollsAutomatically: Bool = true) {
        self.defaults = defaults
        self.clock = clock
        self.pollsAutomatically = pollsAutomatically
        let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let shown = Set((defaults.stringArray(forKey: Self.shownKey) ?? []).compactMap(OnboardingTip.init(rawValue:)))
        scheduler = TipScheduler(tipsEnabled: enabled, shown: shown)
    }

    /// The moment for `tip` has come: show it now if nothing stands in the way,
    /// otherwise keep it waiting (up to `TipScheduler.pendingLifetime`).
    func request(_ tip: OnboardingTip) {
        guard scheduler.request(tip, now: clock()) else { return }
        evaluate()
        schedulePollIfNeeded()
    }

    func withdraw(_ tip: OnboardingTip) {
        scheduler.withdraw(tip)
    }

    /// Re-checks waiting tips, and retires an active tip that no longer makes sense.
    func evaluate() {
        if let active = scheduler.activeTip, !relevance(active) {
            scheduler.dismissActive()
        }
        let before = scheduler.activeTip
        _ = scheduler.nextTip(now: clock(), conditions: conditionsProvider(), isRelevant: relevance)
        if scheduler.activeTip != before { persist() }
    }

    /// "Got it" (or the close button).
    func dismissActive() {
        scheduler.dismissActive()
        evaluateSoon()
    }

    /// "Don't Show Tips".
    func disableAll() {
        tipsEnabled = false
    }

    /// Help ▸ Reset Tips.
    func reset() {
        scheduler.reset()
        persist()
    }

    func hasShown(_ tip: OnboardingTip) -> Bool { scheduler.shown.contains(tip) }

    private func persist() {
        defaults.set(scheduler.tipsEnabled, forKey: Self.enabledKey)
        defaults.set(scheduler.shown.map(\.rawValue).sorted(), forKey: Self.shownKey)
    }

    private func evaluateSoon() {
        schedulePollIfNeeded()
    }

    private func schedulePollIfNeeded() {
        guard pollsAutomatically, pollTask == nil, !scheduler.pending.isEmpty else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self else { return }
                self.evaluate()
                if self.scheduler.pending.isEmpty {
                    self.pollTask = nil
                    return
                }
            }
        }
    }
}
