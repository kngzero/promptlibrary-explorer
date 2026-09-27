import AppKit
import Foundation
import Observation

/// Explicit downloads of online-only (dataless) cloud files, and the live
/// "is this tile still online-only" state the grid, list and lightbox show.
///
/// Nothing here runs implicitly: background work skips dataless files
/// (`CloudFileStatus.isLocallyAvailable`), and only a user action — Download, Make
/// Available Offline, or opening a file in the lightbox with "Download files
/// automatically when opened" on — fetches one.
@MainActor @Observable
final class CloudFileController {
    static let shared = CloudFileController()

    static let autoDownloadKey = "cloud.autoDownloadOnOpen"

    /// Paths being downloaded now.
    private(set) var downloading: Set<String> = []
    /// Paths downloaded in this session (their listing entries may still say
    /// `isCloudOnly` until the next refresh).
    private(set) var materialized: Set<String> = []
    /// Paths whose last download failed, with the reason.
    private(set) var failures: [String: String] = [:]

    /// Settings ▸ Integrations: fetch an online-only file when it's explicitly opened
    /// (lightbox, Open). Never applies to thumbnails, indexing or hover scrubbing.
    var autoDownloadOnOpen: Bool {
        didSet { defaults.set(autoDownloadOnOpen, forKey: Self.autoDownloadKey) }
    }

    /// Called with the paths that finished downloading (the view model refreshes them).
    @ObservationIgnored var onDownloaded: (([String]) -> Void)?
    @ObservationIgnored var onMessage: ((String, ToastType) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoDownloadOnOpen = defaults.object(forKey: Self.autoDownloadKey) as? Bool ?? true
    }

    // MARK: State

    /// Online-only right now: the listing said so and it hasn't been downloaded since.
    func isCloudOnly(_ item: FileEntry) -> Bool {
        guard item.isCloudOnly, !item.isDirectory else { return false }
        return !materialized.contains(item.path)
    }

    func isDownloading(_ path: String) -> Bool {
        downloading.contains(path)
    }

    /// Live check for a path whose listing entry isn't at hand (lightbox, intents).
    func isCloudOnly(path: String) -> Bool {
        guard !materialized.contains(path) else { return false }
        return !CloudFileStatus.isLocallyAvailable(path: path)
    }

    // MARK: Actions

    /// Downloads each online-only file in `urls` (others are ignored). Cancellable per
    /// file via `cancel(_:)`; `onDownloaded` fires once per finished batch.
    func download(_ urls: [URL], announce: Bool = true) {
        let pending = urls.map(\.standardizedFileURL).filter { url in
            !downloading.contains(url.path) && !CloudFileStatus.isLocallyAvailable(url)
        }
        guard !pending.isEmpty else {
            if announce, !urls.isEmpty { onMessage?("Already downloaded", .info) }
            return
        }
        if announce {
            onMessage?(pending.count == 1
                ? "Downloading \u{201C}\(pending[0].lastPathComponent)\u{201D}…"
                : "Downloading \(pending.count) files…", .info)
        }
        for url in pending {
            let path = url.path
            downloading.insert(path)
            failures[path] = nil
            tasks[path] = Task { [weak self] in
                let result = await Self.materialize(url)
                guard let self else { return }
                self.downloading.remove(path)
                self.tasks[path] = nil
                switch result {
                case .success:
                    self.materialized.insert(path)
                    self.onDownloaded?([path])
                case .failure(let error):
                    if !(error is CancellationError) {
                        self.failures[path] = error.localizedDescription
                        self.onMessage?("Couldn't download \u{201C}\(url.lastPathComponent)\u{201D}: \(error.localizedDescription)", .error)
                    }
                }
            }
        }
    }

    /// Downloads, then shows the files in Finder: pinning ("Make Available Offline",
    /// "Keep Downloaded") belongs to the provider and has no public API for other apps,
    /// so Finder's own command is where it's set.
    func makeAvailableOffline(_ urls: [URL]) {
        download(urls, announce: false)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls.prefix(200)))
        onMessage?("Downloading. To keep \(urls.count == 1 ? "it" : "them") downloaded, use Finder\u{2019}s \u{201C}Make Available Offline\u{201D} (Dropbox, Google Drive) or \u{201C}Keep Downloaded\u{201D} (iCloud Drive) on the selected file\(urls.count == 1 ? "" : "s").", .info)
    }

    func cancel(_ path: String) {
        tasks[path]?.cancel()
    }

    /// Lightbox / Open: downloads when the setting allows it. Returns true when a
    /// download started (or is running).
    @discardableResult
    func downloadForExplicitOpen(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if downloading.contains(path) { return true }
        guard autoDownloadOnOpen, isCloudOnly(path: path) else { return false }
        download([url], announce: false)
        return true
    }

    // MARK: Materializing (off the main actor)

    struct DownloadTimeout: LocalizedError {
        var errorDescription: String? { "The download didn't finish in time." }
    }

    /// Asks the provider for the file and waits for its contents. A coordinated read
    /// of one byte is what makes a File Provider (Dropbox, Google Drive) materialize a
    /// dataless file; iCloud also gets `startDownloadingUbiquitousItem`.
    nonisolated static func materialize(_ url: URL, timeout: TimeInterval = 15 * 60) async -> Result<Void, Error> {
        let reader = Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            var coordinationError: NSError?
            var readError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
                do {
                    let handle = try FileHandle(forReadingFrom: readURL)
                    _ = try handle.read(upToCount: 1)
                    try handle.close()
                } catch {
                    readError = error
                }
            }
            if let error = coordinationError ?? readError { return .failure(error) }
            return .success(())
        }
        let started = Date()
        let readResult = await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            reader.cancel()
        }
        if case .failure = readResult, CloudFileStatus.isLocallyAvailable(url) { return .success(()) }
        if case .failure(let error) = readResult { return .failure(error) }
        // The read returned; iCloud can still be finishing. Poll the flag.
        while !CloudFileStatus.isLocallyAvailable(url) {
            if Task.isCancelled { return .failure(CancellationError()) }
            if Date().timeIntervalSince(started) > timeout { return .failure(DownloadTimeout()) }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return .success(())
    }
}
