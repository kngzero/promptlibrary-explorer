import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Observation

/// Owns the edit recipes (persisted curation data), the open editor session and the
/// lightbox's per-file "Show Original" toggle. Originals are never modified: every
/// edit is a recipe the app applies when it shows or exports the file.
@MainActor @Observable
final class EditController {
    static let shared = EditController()

    private(set) var book: EditBook
    /// The editor page's session (nil when the page is closed).
    var session: EditorSession?
    /// Files the lightbox is showing unedited (per file, until toggled back).
    private(set) var showingOriginal: Set<String> = []
    private(set) var originalPreviews: [String: NSImage] = [:]

    @ObservationIgnored private let store: EditStore
    @ObservationIgnored private let index: EditRecipeIndex
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var isSaving = false
    /// Called after recipes changed (sync, import, undo): the view model refreshes the
    /// details / lightbox preview of the files involved.
    @ObservationIgnored var onRecipesChanged: ((Set<String>) -> Void)?

    init(store: EditStore = EditStore(), index: EditRecipeIndex = .shared) {
        self.store = store
        self.index = index
        book = store.load()
        index.replaceAll(book.recipes)
        // Imports, restores and library sync write the store directly.
        observer = NotificationCenter.default.addObserver(
            forName: CurationStoreEvents.didChange, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.userInfo?[CurationStoreEvents.kindKey] as? String) == CurationStoreKind.edits.rawValue else { return }
            MainActor.assumeIsolated { self?.reloadBook() }
        }
    }

    // MARK: Queries

    /// The recipe `path` is shown with (nil when unedited or not an editable image).
    func recipe(for path: String) -> EditRecipe? {
        guard let recipe = book.recipes[path], !recipe.isIdentity,
              EditEligibility.isEditable((path as NSString).lastPathComponent)
        else { return nil }
        return recipe
    }

    func isEdited(_ path: String) -> Bool { recipe(for: path) != nil }

    /// Changes whenever `path`'s recipe does ("" when unedited): part of thumbnail task ids.
    func token(for path: String) -> String { recipe(for: path)?.hashToken ?? "" }

    var editedCount: Int { book.recipes.count }

    // MARK: Writes

    /// Writes `values` (nil = revert to original) and returns what they replaced, for undo.
    @discardableResult
    func apply(_ values: [String: EditRecipe?]) -> [String: EditRecipe?] {
        var next = book
        var replaced: [String: EditRecipe?] = [:]
        for (path, recipe) in values {
            let previous = next.set(recipe, for: path)
            if previous != next.recipes[path] { replaced[path] = .some(previous) }
        }
        guard !replaced.isEmpty else { return [:] }
        commit(next, changed: Set(replaced.keys))
        return replaced
    }

    @discardableResult
    func setRecipe(_ recipe: EditRecipe?, for path: String) -> EditRecipe? {
        let replaced = apply([path: recipe])
        return replaced[path] ?? nil
    }

    private func commit(_ next: EditBook, changed: Set<String>) {
        book = next
        index.replaceAll(next.recipes)
        isSaving = true
        store.save(next)
        isSaving = false
        onRecipesChanged?(changed)
    }

    private func reloadBook() {
        guard !isSaving else { return }
        let loaded = store.load()
        guard loaded != book else { return }
        let changed = Set(loaded.recipes.keys).union(book.recipes.keys).filter { loaded.recipes[$0] != book.recipes[$0] }
        book = loaded
        index.replaceAll(loaded.recipes)
        onRecipesChanged?(changed)
    }

    // MARK: Path hooks (rename / move / trash / undo)

    func itemDidMove(from oldPath: String, to newPath: String) {
        var next = book
        if next.migrate(from: oldPath, to: newPath) { commit(next, changed: [oldPath, newPath]) }
        if let session, let rewritten = MetadataPathKeys.rewrite(session.path, from: oldPath, to: newPath) {
            session.path = rewritten
        }
        if let rewritten = MetadataPathKeys.migratingKeys(of: originalPreviews, from: oldPath, to: newPath) {
            originalPreviews = rewritten
        }
        let moved = Set(showingOriginal.map { MetadataPathKeys.rewrite($0, from: oldPath, to: newPath) ?? $0 })
        if moved != showingOriginal { showingOriginal = moved }
    }

    /// Removes and returns the recipes at or under `path` (they go into the trash's
    /// undo snapshot, like ratings).
    func removeAll(under path: String) -> [String: EditRecipe] {
        var next = book
        let removed = next.removeAll(under: path)
        if !removed.isEmpty { commit(next, changed: Set(removed.keys)) }
        return removed
    }

    func restore(_ snapshot: [String: EditRecipe], from oldPath: String, to newPath: String) {
        guard !snapshot.isEmpty else { return }
        var next = book
        next.restore(snapshot, from: oldPath, to: newPath)
        let changed = Set(snapshot.keys.map { MetadataPathKeys.rewrite($0, from: oldPath, to: newPath) ?? $0 })
        commit(next, changed: changed)
    }

    // MARK: Lightbox "Show Original"

    func isShowingOriginal(_ path: String) -> Bool { showingOriginal.contains(path) }

    /// The unedited preview while "Show Original" is on for `path` (nil until loaded).
    func originalPreview(for path: String) -> NSImage? {
        guard showingOriginal.contains(path) else { return nil }
        return originalPreviews[path]
    }

    func toggleShowOriginal(_ path: String) {
        if showingOriginal.contains(path) {
            showingOriginal.remove(path)
            return
        }
        showingOriginal.insert(path)
        guard originalPreviews[path] == nil else { return }
        Task {
            let image = await ThumbnailService.shared.previewImage(for: URL(fileURLWithPath: path), ignoringEdits: true)
            guard let image, showingOriginal.contains(path) else { return }
            if originalPreviews.count > 4 { originalPreviews.removeAll() }
            originalPreviews[path] = image
        }
    }

    func clearShowOriginal(_ path: String) {
        showingOriginal.remove(path)
        originalPreviews.removeValue(forKey: path)
    }
}

// MARK: - Editor session

enum EditorTool: String, CaseIterable, Identifiable {
    case crop
    case adjust

    var id: String { rawValue }
    var title: String { self == .crop ? "Crop & Rotate" : "Adjust" }
    var systemImage: String { self == .crop ? "crop.rotate" : "slider.horizontal.3" }
}

/// One open editor: the working recipe with its own undo / redo, a downsampled
/// working copy of the image and the rendered preview. Nothing is saved until Done.
@MainActor @Observable
final class EditorSession: Identifiable {
    let id = UUID()
    var path: String
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }

    /// The recipe saved for the file when the editor opened (Cancel goes back to it).
    let savedRecipe: EditRecipe
    private(set) var recipe: EditRecipe
    private(set) var undoStack: [EditRecipe] = []
    private(set) var redoStack: [EditRecipe] = []
    var tool: EditorTool = .crop {
        didSet { if tool != oldValue { scheduleRender() } }
    }

    /// Oriented full-resolution size of the file.
    private(set) var sourceSize: CGSize = .zero
    private(set) var isLoading = true
    private(set) var loadError: String?
    /// The latest render of the working recipe (the full frame in the crop tool).
    private(set) var preview: CGImage?
    /// The unedited working copy, for "hold to compare".
    private(set) var baseImage: CGImage?
    /// True while the Compare button is held: the canvas shows the original.
    var isComparing = false
    /// True while the straighten slider is dragged (the canvas shows a finer grid).
    var isStraightening = false
    /// Reopen the lightbox on this file when the editor closes.
    var returnToLightbox = false

    @ObservationIgnored private var isLoadStarted = false
    /// The crop follows straighten / aspect changes until the user drags it.
    private var autoCrop: Bool
    private var interactiveUndoPushed = false
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderGeneration = 0

    static let workingLongEdge: CGFloat = 2400
    static let undoLimit = 100

    init(path: String, savedRecipe: EditRecipe?) {
        self.path = path
        let saved = (savedRecipe ?? .identity).normalized()
        self.savedRecipe = saved
        recipe = saved
        autoCrop = saved.crop == nil
    }

    var isDirty: Bool { recipe.normalized() != savedRecipe.normalized() }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var outputSize: CGSize { EditGeometry.outputSize(for: recipe, sourceSize: sourceSize) }

    /// The crop in display space (the turned, flipped frame), normalized.
    var displayCrop: EditRect {
        EditGeometry.displayRect(fromCrop: recipe.crop ?? .full, quarterTurns: recipe.quarterTurns, flipH: recipe.flipHorizontal, flipV: recipe.flipVertical)
    }

    /// Display frame pixel size (source size, turned).
    var displayFrameSize: CGSize {
        recipe.swapsAxes ? CGSize(width: sourceSize.height, height: sourceSize.width) : sourceSize
    }

    /// Output ratio the aspect preset locks (nil = free).
    var lockedOutputRatio: Double? {
        recipe.aspect.ratio(originalRatio: EditGeometry.frameRatio(sourceSize: sourceSize, quarterTurns: recipe.quarterTurns))
    }

    // MARK: Loading

    func load() async {
        guard baseImage == nil, !isLoadStarted else { return }
        isLoadStarted = true
        let url = url
        let longEdge = Self.workingLongEdge
        let loaded = await Task.detached(priority: .userInitiated) { () -> (CGImage, CGSize)? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let size = EditRenderer.orientedPixelSize(of: source)
            else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: min(longEdge, max(size.width, size.height)),
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return (image, size)
        }.value
        isLoading = false
        guard let (image, size) = loaded else {
            loadError = "The image couldn't be read."
            return
        }
        baseImage = image
        sourceSize = size
        scheduleRender()
    }

    // MARK: Changes

    /// A discrete change (button, picker): one undo step.
    func change(_ body: (inout EditRecipe) -> Void) {
        var next = recipe
        body(&next)
        next = next.normalized()
        guard next != recipe else { return }
        pushUndo()
        recipe = next
        scheduleRender()
    }

    /// Slider / drag gestures: call `beginInteraction` once, then `interactiveChange`
    /// for every move; the whole gesture is one undo step.
    func beginInteraction() {
        interactiveUndoPushed = false
    }

    func interactiveChange(_ body: (inout EditRecipe) -> Void) {
        var next = recipe
        body(&next)
        next = next.normalized()
        guard next != recipe else { return }
        if !interactiveUndoPushed {
            pushUndo()
            interactiveUndoPushed = true
        }
        recipe = next
        scheduleRender()
    }

    func endInteraction() {
        interactiveUndoPushed = false
        isStraightening = false
    }

    private func pushUndo() {
        undoStack.append(recipe)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(recipe)
        recipe = previous
        autoCrop = previous.crop == nil
        scheduleRender()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        recipe = next
        autoCrop = next.crop == nil
        scheduleRender()
    }

    // MARK: Tools

    func rotate(clockwise: Bool) {
        change { recipe in
            recipe.quarterTurns += clockwise ? 1 : 3
            // A fixed non-square ratio would turn with the image; keep the crop as is.
            if ![.free, .original, .square].contains(recipe.aspect) { recipe.aspect = .free }
        }
    }

    func flip(horizontal: Bool) {
        change { recipe in
            if horizontal { recipe.flipHorizontal.toggle() } else { recipe.flipVertical.toggle() }
        }
    }

    func setAspect(_ aspect: EditAspect) {
        guard sourceSize.width > 0 else { return }
        change { recipe in
            recipe.aspect = aspect
            let ratio = EditGeometry.cropPixelRatio(for: aspect, sourceSize: sourceSize, quarterTurns: recipe.quarterTurns)
            guard ratio != nil else { return }
            if autoCrop || recipe.crop == nil {
                recipe.crop = EditGeometry.maxCrop(ratio: ratio, angle: recipe.straighten, sourceSize: sourceSize)
            } else {
                recipe.crop = EditGeometry.applyingRatio(ratio, to: recipe.crop ?? .full, angle: recipe.straighten, sourceSize: sourceSize)
            }
        }
    }

    /// Straighten slider (interactive): the crop shrinks to keep the corners filled.
    func setStraighten(_ degrees: Double) {
        guard sourceSize.width > 0 else { return }
        isStraightening = true
        interactiveChange { recipe in
            recipe.straighten = min(max(degrees, EditRecipe.straightenRange.lowerBound), EditRecipe.straightenRange.upperBound)
            recipe.crop = cropFollowingStraighten(recipe)
        }
    }

    /// Discrete straighten (reset button, typed value).
    func setStraightenDiscrete(_ degrees: Double) {
        guard sourceSize.width > 0 else { return }
        change { recipe in
            recipe.straighten = min(max(degrees, EditRecipe.straightenRange.lowerBound), EditRecipe.straightenRange.upperBound)
            recipe.crop = cropFollowingStraighten(recipe)
        }
    }

    private func cropFollowingStraighten(_ recipe: EditRecipe) -> EditRect? {
        let ratio = EditGeometry.cropPixelRatio(for: recipe.aspect, sourceSize: sourceSize, quarterTurns: recipe.quarterTurns)
        if autoCrop {
            let rect = EditGeometry.maxCrop(ratio: ratio, angle: recipe.straighten, sourceSize: sourceSize)
            return rect.isFull ? nil : rect
        }
        return EditGeometry.fitted(recipe.crop ?? .full, angle: recipe.straighten, sourceSize: sourceSize)
    }

    /// A crop drag proposes `display` (display space, normalized); the crop stops where
    /// an empty corner would show.
    func proposeDisplayCrop(_ display: EditRect) {
        guard sourceSize.width > 0 else { return }
        autoCrop = false
        interactiveChange { recipe in
            let candidate = EditGeometry.cropRect(fromDisplay: display, quarterTurns: recipe.quarterTurns, flipH: recipe.flipHorizontal, flipV: recipe.flipVertical)
            let current = recipe.crop ?? EditGeometry.maxCrop(ratio: nil, angle: recipe.straighten, sourceSize: sourceSize)
            recipe.crop = EditGeometry.constrained(from: current, toward: candidate, angle: recipe.straighten, sourceSize: sourceSize)
        }
    }

    func resetCrop() {
        guard sourceSize.width > 0 else { return }
        autoCrop = true
        change { recipe in
            let ratio = EditGeometry.cropPixelRatio(for: recipe.aspect, sourceSize: sourceSize, quarterTurns: recipe.quarterTurns)
            let rect = EditGeometry.maxCrop(ratio: ratio, angle: recipe.straighten, sourceSize: sourceSize)
            recipe.crop = rect.isFull ? nil : rect
        }
    }

    /// Crop, straighten, rotation and flips back to none (adjustments stay).
    func resetGeometry() {
        autoCrop = true
        change { recipe in
            recipe.crop = nil
            recipe.straighten = 0
            recipe.quarterTurns = 0
            recipe.flipHorizontal = false
            recipe.flipVertical = false
            recipe.aspect = .free
        }
    }

    func resetAdjustments() {
        change { recipe in
            recipe.exposure = 0
            recipe.contrast = 0
            recipe.saturation = 0
            recipe.temperature = 0
        }
    }

    /// Everything back to the file as it is (undoable inside the session).
    func revertToOriginal() {
        autoCrop = true
        change { $0 = .identity }
    }

    // MARK: Rendering

    func scheduleRender() {
        guard let base = baseImage else { return }
        renderTask?.cancel()
        renderGeneration &+= 1
        let generation = renderGeneration
        let recipe = recipe
        let fullFrame = tool == .crop
        renderTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                EditRenderer.render(base, recipe: recipe, showingFullFrame: fullFrame)
            }.value
            guard let self, !Task.isCancelled, generation == self.renderGeneration else { return }
            self.preview = image
        }
    }

    func cancelRender() {
        renderTask?.cancel()
    }
}
