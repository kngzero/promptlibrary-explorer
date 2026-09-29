import AppKit
import Foundation

// Pure models behind the Similar Images page (Library ▸ Similar Images): a
// full-page mode of the main window that replaces the content browser and the
// details panel while the sidebar stays.
//
// HARD RULE (user decision): similar / duplicate results are for inspection
// only. Nothing here marks, pre-selects, ranks for removal or offers to delete
// any file — every file in a group is kept (a larger copy is often an upscale
// of the master). Cards keep the engine's display order (folder, then name).

// MARK: - Page mode

/// What the main window's content + details area shows. Never persisted: the
/// app always starts in the browser.
enum MainPageMode: Equatable, Sendable {
    case browser
    case similarImages
}

/// Folder, root and scope choice the page's results depend on.
struct SimilarPageContext: Equatable, Sendable {
    var folderPath: String?
    var rootPath: String?
    var scope: VisualSearchScopeChoice

    init(folderPath: String?, rootPath: String?, scope: VisualSearchScopeChoice) {
        self.folderPath = folderPath.map(Self.normalized)
        self.rootPath = rootPath.map(Self.normalized)
        self.scope = scope
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// Navigation elsewhere in the window while the page is up.
enum SimilarPageNavigationEvent: Equatable, Sendable {
    /// The sidebar showed a collection.
    case collectionOpened
    /// The sidebar (or the command palette) activated a smart folder.
    case smartFolderActivated
    /// A tag filter was picked (command palette).
    case tagFilterChanged
    /// A file was revealed in the browser (library search, Finder "Open With").
    case fileRevealed
}

enum SimilarPageNavigationEffect: Equatable, Sendable {
    case none
    /// The scope moved: search again (instant when cached).
    case rerunSearch
    /// The browser has to show something: the page closed.
    case leftPage
}

/// Enter / leave state machine for the page. Entering and leaving never touch
/// the browser's folder, listing or selection, so leaving shows the browser
/// exactly as it was (see `SimilarPageBrowserSnapshot` for the one flow — the
/// lightbox — that borrows the hidden browser and puts it back).
struct SimilarPageModeState: Equatable, Sendable {
    private(set) var mode: MainPageMode = .browser

    var isActive: Bool { mode == .similarImages }

    mutating func enter() { mode = .similarImages }
    mutating func leave() { mode = .browser }

    mutating func toggle() {
        if isActive { leave() } else { enter() }
    }

    /// Sidebar collection / smart folder / tag clicks and file reveals show
    /// the browser, so they leave the page.
    @discardableResult
    mutating func handle(_ event: SimilarPageNavigationEvent) -> SimilarPageNavigationEffect {
        guard isActive else { return .none }
        leave()
        return .leftPage
    }

    /// A folder click keeps the page: with This Folder the search follows the
    /// new folder; with Whole Library results stay unless the root changed.
    func effect(from old: SimilarPageContext, to new: SimilarPageContext) -> SimilarPageNavigationEffect {
        guard isActive else { return .none }
        if old.scope != new.scope || old.rootPath != new.rootPath { return .rerunSearch }
        if new.scope == .folder, old.folderPath != new.folderPath { return .rerunSearch }
        return .none
    }
}

// MARK: - Actions (no deletion of any kind)

/// What one card (a file in a group) offers: hover buttons and its context
/// menu. The flag / rating / label submenus are the regular culling actions.
enum SimilarCardAction: String, CaseIterable, Identifiable, Sendable {
    case openInLightbox
    case showInFolder
    case revealInFinder
    case moreLikeThis
    case copyPrompt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openInLightbox: return "Open in Lightbox"
        case .showInFolder: return "Show in Folder"
        case .revealInFinder: return "Reveal in Finder"
        case .moreLikeThis: return "More Like This"
        case .copyPrompt: return "Copy Prompt"
        }
    }

    var systemImage: String {
        switch self {
        case .openInLightbox: return "arrow.up.left.and.arrow.down.right"
        case .showInFolder: return "folder"
        case .revealInFinder: return "arrow.up.forward.app"
        case .moreLikeThis: return "sparkle.magnifyingglass"
        case .copyPrompt: return "doc.on.doc"
        }
    }

    /// Hover buttons and context-menu items, in display order.
    static let displayOrder: [SimilarCardAction] = [.openInLightbox, .showInFolder, .revealInFinder, .moreLikeThis, .copyPrompt]
}

/// What the selected group offers (header of the comparison area).
enum SimilarGroupPageAction: String, CaseIterable, Identifiable, Sendable {
    case selectInBrowser
    case addToCollection
    case openAsListing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selectInBrowser: return "Select in Browser"
        case .addToCollection: return "Add to Collection…"
        case .openAsListing: return "Open Group as Listing"
        }
    }

    var systemImage: String {
        switch self {
        case .selectInBrowser: return "checkmark.circle"
        case .addToCollection: return "rectangle.stack.badge.plus"
        case .openAsListing: return "square.grid.2x2"
        }
    }

    static let displayOrder: [SimilarGroupPageAction] = [.selectInBrowser, .addToCollection, .openAsListing]
}

// MARK: - Keys

/// Keys the page owns while it's up (via the main window's key monitor,
/// `handleGlobalKey`). Bare keys only: anything with ⌘ ⌃ ⌥ ⇧ belongs to the
/// menus / system, so it passes through.
enum SimilarPageKeyAction: Equatable, Sendable {
    case previousGroup
    case nextGroup
    case previousCard
    case nextCard
    /// Space / Return: the focused card in the lightbox.
    case openLightbox
    /// M: More Like This for the focused card.
    case moreLikeThis
    /// P X U 0–9 on the focused card.
    case cull(CullAction)
    /// Esc: back to the browser.
    case leave

    /// Repeating (a held key) is fine for moving focus, never for actions.
    var allowsRepeat: Bool {
        switch self {
        case .previousGroup, .nextGroup, .previousCard, .nextCard: return true
        default: return false
        }
    }

    static func action(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> SimilarPageKeyAction? {
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch keyCode {
        case KeyCode.upArrow.rawValue: return .previousGroup
        case KeyCode.downArrow.rawValue: return .nextGroup
        case KeyCode.leftArrow.rawValue: return .previousCard
        case KeyCode.rightArrow.rawValue: return .nextCard
        case KeyCode.space.rawValue, KeyCode.returnKey.rawValue: return .openLightbox
        case KeyCode.escape.rawValue: return .leave
        default: break
        }
        if VisualSearchKeys.isMoreLikeThis(characters: characters, modifiers: modifiers) { return .moreLikeThis }
        if let characters, let action = CullAction(keyCharacters: characters) { return .cull(action) }
        return nil
    }
}

// MARK: - Focus

/// The selected group (row in the group list) and the focused card in it.
/// Tracked by id / path so a re-run keeps focus on the same files.
struct SimilarPageFocus: Equatable, Sendable {
    var groupID: String?
    var path: String?

    init(groupID: String? = nil, path: String? = nil) {
        self.groupID = groupID
        self.path = path
    }

    func groupIndex(in sets: [SimilarSet]) -> Int? {
        guard let groupID else { return nil }
        return sets.firstIndex { $0.id == groupID }
    }

    func cardIndex(in sets: [SimilarSet]) -> Int? {
        guard let group = groupIndex(in: sets), let path else { return nil }
        return sets[group].paths.firstIndex(of: path)
    }

    /// Focus that exists in `sets`: the same group and card when still there,
    /// else the group's first card, else the first group.
    func resolved(in sets: [SimilarSet]) -> SimilarPageFocus {
        guard !sets.isEmpty else { return SimilarPageFocus() }
        let set = sets[groupIndex(in: sets) ?? 0]
        let keptPath = path.flatMap { set.paths.contains($0) ? $0 : nil }
        return SimilarPageFocus(groupID: set.id, path: keptPath ?? set.paths.first)
    }

    /// ↑ / ↓: the previous / next group (stops at either end), focusing its
    /// first card.
    func movingGroup(by step: Int, in sets: [SimilarSet]) -> SimilarPageFocus {
        guard !sets.isEmpty else { return SimilarPageFocus() }
        guard let current = groupIndex(in: sets) else {
            let set = step < 0 ? sets[sets.count - 1] : sets[0]
            return SimilarPageFocus(groupID: set.id, path: set.paths.first)
        }
        let target = min(max(current + step, 0), sets.count - 1)
        guard target != current else { return resolved(in: sets) }
        return SimilarPageFocus(groupID: sets[target].id, path: sets[target].paths.first)
    }

    /// ← / →: the previous / next card of the group (stops at either end).
    func movingCard(by step: Int, in sets: [SimilarSet]) -> SimilarPageFocus {
        let base = resolved(in: sets)
        guard let group = base.groupIndex(in: sets) else { return base }
        let paths = sets[group].paths
        guard !paths.isEmpty else { return base }
        let current = base.cardIndex(in: sets) ?? 0
        let target = min(max(current + step, 0), paths.count - 1)
        return SimilarPageFocus(groupID: base.groupID, path: paths[target])
    }

    /// Selects `groupID` (a row click), focusing its first card.
    func selectingGroup(_ groupID: String, in sets: [SimilarSet]) -> SimilarPageFocus {
        guard let set = sets.first(where: { $0.id == groupID }) else { return resolved(in: sets) }
        if set.id == self.groupID { return resolved(in: sets) }
        return SimilarPageFocus(groupID: set.id, path: set.paths.first)
    }

    /// Focuses `path` in the group that holds it (a card click).
    func focusing(_ path: String, in sets: [SimilarSet]) -> SimilarPageFocus {
        if let group = groupIndex(in: sets), sets[group].paths.contains(path) {
            return SimilarPageFocus(groupID: groupID, path: path)
        }
        guard let set = sets.first(where: { $0.paths.contains(path) }) else { return resolved(in: sets) }
        return SimilarPageFocus(groupID: set.id, path: path)
    }
}

// MARK: - Results cache

/// One search: scope + strictness (to 0.01) + whether videos take part.
struct SimilarResultsKey: Hashable, Sendable {
    let scope: VisualScope
    let strictness: Double
    let includeVideos: Bool

    init(scope: VisualScope, strictness: Double, includeVideos: Bool) {
        self.scope = scope
        self.strictness = Self.rounded(strictness)
        self.includeVideos = includeVideos
    }

    static func rounded(_ strictness: Double) -> Double {
        guard strictness.isFinite else { return 0.85 }
        return (min(max(strictness, 0), 1) * 100).rounded() / 100
    }

    /// True when a change at `path` (a file, or a folder / root that was
    /// re-indexed) can change this search's groups.
    func isAffected(byChangeAt path: String) -> Bool {
        let changed = VisualIndexService.normalizedPath(path)
        switch scope {
        case let .folder(url):
            let folder = VisualIndexService.normalizedPath(url.path)
            return VisualIndexService.parentPath(changed) == folder
                || VisualIndexService.isSameOrDescendant(folder, of: changed)
        case let .library(url):
            let root = VisualIndexService.normalizedPath(url.path)
            return VisualIndexService.isSameOrDescendant(changed, of: root)
                || VisualIndexService.isSameOrDescendant(root, of: changed)
        }
    }
}

struct SimilarResultsEntry: Sendable {
    let sets: [SimilarSet]
    let info: [String: SimilarImageInfo]
    let indexedCount: Int?
}

/// Last results per search, so leaving and re-entering the page (or going
/// back to a folder) is instant. Dropped when the visual index changes for
/// paths a search covers.
struct SimilarResultsCache: Sendable {
    static let defaultCapacity = 8

    private(set) var entries: [SimilarResultsKey: SimilarResultsEntry] = [:]
    /// Least recently used first.
    private(set) var order: [SimilarResultsKey] = []
    let capacity: Int

    init(capacity: Int = SimilarResultsCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    func entry(for key: SimilarResultsKey) -> SimilarResultsEntry? {
        entries[key]
    }

    mutating func store(_ entry: SimilarResultsEntry, for key: SimilarResultsKey) {
        entries[key] = entry
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            let evicted = order.removeFirst()
            entries[evicted] = nil
        }
    }

    /// Marks `key` as just used.
    mutating func touch(_ key: SimilarResultsKey) {
        guard entries[key] != nil else { return }
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Drops every search a change at any of `paths` can affect.
    mutating func invalidate(paths: [String]) {
        guard !paths.isEmpty else { return }
        let stale = entries.keys.filter { key in paths.contains { key.isAffected(byChangeAt: $0) } }
        for key in stale { entries[key] = nil }
        order.removeAll { entries[$0] == nil }
    }

    mutating func removeAll() {
        entries = [:]
        order = []
    }
}

// MARK: - Borrowing the hidden browser (lightbox)

/// The browser's listing and selection, captured before the page opens a
/// group in the lightbox (the lightbox walks the browser's listing, so the
/// group is shown there as a virtual listing underneath the page) and put
/// back when the lightbox closes.
struct SimilarPageBrowserSnapshot: Equatable, Sendable {
    var listing: ListingModeState
    var smartFolderID: UUID?
    var selectedPaths: [String]
    var primaryPath: String?

    enum RestoreStep: Equatable, Sendable {
        /// The listing is already the snapshot's.
        case none
        /// Close the virtual listing: that returns to the snapshot's folder or collection.
        case closeVirtualListing
        /// Re-open the virtual listing the browser showed.
        case openVirtual(VirtualListing)
        /// Show this collection (nil: the folder).
        case openCollection(UUID?)
    }

    /// How to get from `current` back to the snapshot's listing.
    func restoreStep(from current: ListingModeState) -> RestoreStep {
        switch (listing.mode, current.mode) {
        case (.folder, .folder):
            return .none
        case let (.collection(want), .collection(have)) where want == have:
            return .none
        case let (.virtual(want), .virtual(have)) where want.id == have.id:
            return .none
        case let (.virtual(want), _):
            return .openVirtual(want)
        case (.folder, .virtual):
            var closing = current
            closing.closeVirtual()
            return closing.mode == .folder ? .closeVirtualListing : .openCollection(nil)
        case (.folder, .collection):
            return .openCollection(nil)
        case let (.collection(want), .virtual):
            var closing = current
            closing.closeVirtual()
            return closing.mode == .collection(want) ? .closeVirtualListing : .openCollection(want)
        case let (.collection(want), _):
            return .openCollection(want)
        }
    }
}

/// A lightbox the page opened: what to put back, and which listing it borrowed.
struct SimilarPageLightboxSession: Equatable, Sendable {
    let snapshot: SimilarPageBrowserSnapshot
    /// The group's virtual listing. If the browser shows something else when
    /// the lightbox closes (More Like This from inside the lightbox), the user
    /// moved on: the page closes and the browser keeps the new listing.
    let groupListingID: UUID
}
