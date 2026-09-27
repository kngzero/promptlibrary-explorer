import Foundation
import Observation

/// Owns version-stack state for the browser: which listings show stacks (View ▸ Stack
/// Variants, per folder or collection), the manual stack book, the stacks detected for
/// the current listing and which of them are expanded. Detection runs off the main actor.
///
/// Semantics (see Help): a collapsed stack is one tile standing for its members — the
/// cover. Selecting it selects the cover only, so ratings, flags, tags, drags and every
/// other action apply to the cover unless the stack is expanded. Covers are display-only
/// and the feature never marks or suggests files for deletion.
@MainActor @Observable
final class StackController {
    static let shared = StackController()

    /// Stacks detected for the current listing (manual + automatic).
    private(set) var stacks: [FileStack] = [] {
        didSet { rebuildIndex() }
    }
    /// Expanded stack ids (the listing shows their members inline).
    private(set) var expanded: Set<String> = []
    /// Listing scopes (folder path, `collection:<id>`) with Stack Variants on.
    private(set) var enabledScopes: Set<String>
    private(set) var book: StackBook
    /// Bumped whenever anything that changes the stacked listing changes.
    private(set) var revision = 0
    private(set) var isDetecting = false

    /// Written by the listing pipeline (not observed: the listing itself is).
    @ObservationIgnored var presentation = StackPresentation()
    /// Called after stacks / expansion changed: the view model re-runs its listing.
    @ObservationIgnored var onPresentationChange: (() -> Void)?
    /// A stack the lightbox expanded to walk its members (collapsed again on close).
    @ObservationIgnored var lightboxExpandedStackID: String?
    /// The listing scope a prompt-data load was last requested for.
    @ObservationIgnored var promptDataRequestedScope: String?

    @ObservationIgnored private var stackIndexByPath: [String: Int] = [:]
    @ObservationIgnored private let store: StackStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var detectionTask: Task<Void, Never>?
    @ObservationIgnored private var detectionID = 0
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var isSaving = false

    static let enabledScopesKey = "stacks.enabledScopes"

    init(store: StackStore = StackStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        book = store.load()
        enabledScopes = Set(defaults.stringArray(forKey: Self.enabledScopesKey) ?? [])
        // Imports, restores and library sync write the store directly.
        observer = NotificationCenter.default.addObserver(
            forName: CurationStoreEvents.didChange, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.userInfo?[CurationStoreEvents.kindKey] as? String) == CurationStoreKind.stacks.rawValue else { return }
            MainActor.assumeIsolated { self?.reloadBook() }
        }
    }

    // MARK: Queries

    func isEnabled(forScope scope: String?) -> Bool {
        guard let scope else { return false }
        return enabledScopes.contains(scope)
    }

    func stack(containing path: String) -> FileStack? {
        let current = stacks   // observed even when `path` isn't stacked yet
        return stackIndexByPath[path].flatMap { $0 < current.count ? current[$0] : nil }
    }

    func stack(withID id: String) -> FileStack? {
        stacks.first { $0.id == id }
    }

    func isExpanded(_ stackID: String) -> Bool { expanded.contains(stackID) }

    // MARK: Toggles

    func setEnabled(_ enabled: Bool, forScope scope: String) {
        guard enabledScopes.contains(scope) != enabled else { return }
        if enabled { enabledScopes.insert(scope) } else { enabledScopes.remove(scope) }
        defaults.set(enabledScopes.sorted(), forKey: Self.enabledScopesKey)
        if !enabled {
            expanded = []
            publish([])
        }
        bump()
    }

    func setExpanded(_ isExpanded: Bool, stackID: String) {
        guard expanded.contains(stackID) != isExpanded else { return }
        if isExpanded { expanded.insert(stackID) } else { expanded.remove(stackID) }
        bump()
    }

    func toggleExpanded(_ stackID: String) {
        setExpanded(!expanded.contains(stackID), stackID: stackID)
    }

    func setAllExpanded(_ isExpanded: Bool) {
        let next: Set<String> = isExpanded ? Set(stacks.map(\.id)) : []
        guard next != expanded else { return }
        expanded = next
        bump()
    }

    // MARK: Book edits (persisted curation data)

    func updateBook(_ body: (inout StackBook) -> Void) {
        var next = book
        body(&next)
        next.normalize()
        guard next != book else { return }
        book = next
        isSaving = true
        store.save(next)
        isSaving = false
        bump()
    }

    /// Rename / move: stacks and per-scope switches follow the item.
    func itemDidMove(from oldPath: String, to newPath: String) {
        var next = book
        if next.migrate(from: oldPath, to: newPath) {
            updateBook { $0 = next }
        }
        var scopes = enabledScopes
        var changed = false
        for scope in enabledScopes {
            if let rewritten = MetadataPathKeys.rewrite(scope, from: oldPath, to: newPath), rewritten != scope {
                scopes.remove(scope)
                scopes.insert(rewritten)
                changed = true
            }
        }
        if changed {
            enabledScopes = scopes
            defaults.set(scopes.sorted(), forKey: Self.enabledScopesKey)
        }
    }

    private func reloadBook() {
        guard !isSaving else { return }
        let loaded = store.load()
        guard loaded != book else { return }
        book = loaded
        bump()
    }

    // MARK: Detection

    /// Recomputes stacks for `candidates` (the listing's visual files) off the main actor.
    /// Visual-index signatures (dHash, pixel size) fill in upscale lineage when present.
    func detect(candidates: [StackCandidate], scope: String, currentScope: @escaping @MainActor () -> String?) {
        detectionTask?.cancel()
        detectionID &+= 1
        let id = detectionID
        let manual = book.stacks
        let excluded = book.excludedPaths
        isDetecting = true
        detectionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let signatures = await VisualIndexService.shared.stackSignatures(forPaths: candidates.map(\.path))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) { () -> [FileStack] in
                let enriched = candidates.map { candidate -> StackCandidate in
                    guard let signature = signatures[candidate.path] else { return candidate }
                    var copy = candidate
                    copy.dHash = signature.dHash
                    if let width = signature.width, let height = signature.height {
                        copy.width = width
                        copy.height = height
                    }
                    return copy
                }
                return StackDetector.detect(candidates: enriched, manual: manual, excluded: excluded)
            }.value
            guard let self, !Task.isCancelled, self.detectionID == id, currentScope() == scope else { return }
            self.isDetecting = false
            self.publish(result)
        }
    }

    func clearStacks() {
        detectionTask?.cancel()
        detectionID &+= 1
        isDetecting = false
        publish([])
    }

    private func publish(_ result: [FileStack]) {
        guard result != stacks else { return }
        let ids = Set(result.map(\.id))
        stacks = result
        let keptExpanded = expanded.intersection(ids)
        if keptExpanded != expanded { expanded = keptExpanded }
        if let lightbox = lightboxExpandedStackID, !ids.contains(lightbox) { lightboxExpandedStackID = nil }
        bump()
    }

    private func rebuildIndex() {
        var index: [String: Int] = [:]
        for (offset, stack) in stacks.enumerated() {
            for member in stack.members where index[member] == nil { index[member] = offset }
        }
        stackIndexByPath = index
    }

    private func bump() {
        revision &+= 1
        onPresentationChange?()
    }
}
