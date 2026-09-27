import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

/// State and commands for the video & audio tools: the hover-scrub setting, the Trim sheet,
/// clip-export progress, and frame export (Save Frame…, Copy Frame, Save Frame Strip…,
/// Save Middle Frame). Views and the view model reach the tools only through this.
@MainActor @Observable
final class MediaController {
    static let shared = MediaController()

    /// A request to show the Trim sheet for one video.
    struct TrimRequest: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        /// Where the lightbox player was, so the sheet can open at the same frame.
        var startTime: Double = 0
    }

    /// Clip-export progress while the Trim sheet exports.
    struct ExportJob: Equatable {
        let destination: URL
        var progress: Double
    }

    // MARK: Settings

    static let hoverScrubKey = "media.hoverScrub.enabled"

    /// Settings ▸ Appearance: move across a video tile to scrub through it (default on).
    var hoverScrubEnabled: Bool {
        didSet { defaults.set(hoverScrubEnabled, forKey: Self.hoverScrubKey) }
    }

    // MARK: State

    var trimRequest: TrimRequest?
    private(set) var exportJob: ExportJob?
    /// Frame / strip saves in flight (buttons show a spinner, repeat clicks are ignored).
    private(set) var isSavingFrame = false

    var isExporting: Bool { exportJob != nil }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    /// Toast sink (the view model's `showToast`), set by the view model glue.
    @ObservationIgnored var toast: (String, ToastType) -> Void = { _, _ in }
    /// Called after a file was written into a folder, so the listing can refresh.
    @ObservationIgnored var didWriteFiles: ([URL]) -> Void = { _ in }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hoverScrubEnabled = defaults.object(forKey: Self.hoverScrubKey) as? Bool ?? true
    }

    // MARK: Trim

    func openTrim(for url: URL, startTime: Double = 0) {
        guard !isExporting else {
            toast("A clip is still exporting.", .info)
            return
        }
        trimRequest = TrimRequest(url: url, startTime: startTime)
    }

    /// Default output for a trim: next to the source, never over it or an existing file.
    func defaultTrimDestination(for source: URL, format: MediaClipExportOptions.Format) -> URL {
        let name = MediaExportNaming.trimFileName(videoName: source.lastPathComponent, fileExtension: format.fileExtension)
        return MediaExportNaming.uniqueURL(for: name, in: source.deletingLastPathComponent(), avoiding: source)
    }

    /// Starts exporting; `completion(true)` on success (called on the main actor).
    func startExport(
        source: URL,
        range: MediaTrimRange,
        options: MediaClipExportOptions,
        destination: URL,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard exportTask == nil else { return }
        guard !MediaExportNaming.isSameFile(destination, source) else {
            toast(MediaToolError.wouldOverwriteSource.localizedDescription, .error)
            completion(false)
            return
        }
        exportJob = ExportJob(destination: destination, progress: 0)
        exportTask = Task { [weak self] in
            do {
                let passthrough = try await MediaClipExporter.export(
                    source: source, range: range, options: options, to: destination
                ) { value in
                    self?.exportJob?.progress = value
                }
                guard let self else { return }
                self.finishExport()
                let how = options.format == .gif ? "" : (passthrough ? " (no re-encode)" : "")
                self.toast("Exported \(destination.lastPathComponent)\(how)", .success)
                self.didWriteFiles([destination])
                completion(true)
            } catch {
                guard let self else { return }
                self.finishExport()
                if error is CancellationError || (error as? MediaToolError).map({ if case .cancelled = $0 { return true } else { return false } }) == true {
                    self.toast("Export cancelled", .info)
                } else {
                    self.toast("Export failed: \(error.localizedDescription)", .error)
                }
                completion(false)
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func finishExport() {
        exportTask = nil
        exportJob = nil
    }

    // MARK: Frames

    /// Save Frame…: the frame at `seconds`, full resolution, PNG or JPEG (save panel).
    func saveFrame(of video: URL, at seconds: Double, displayName: String? = nil) {
        guard !isSavingFrame else { return }
        let name = displayName ?? video.lastPathComponent
        let panel = NSSavePanel()
        panel.title = "Save Frame"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.directoryURL = video.deletingLastPathComponent()
        panel.nameFieldStringValue = MediaExportNaming.frameFileName(videoName: name, seconds: seconds, fileExtension: "png")
        let accessory = FormatAccessory(panel: panel)
        panel.accessoryView = accessory.view
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format = MediaImageFormat(fileExtension: url.pathExtension)
        withExtendedLifetime(accessory) {}

        isSavingFrame = true
        Task {
            defer { isSavingFrame = false }
            do {
                let frame = try await MediaFrameExtractor.frame(at: seconds, url: video)
                try await Task.detached(priority: .userInitiated) {
                    try MediaImageWriter.write(frame, to: url, format: format)
                }.value
                toast("Saved \(url.lastPathComponent)", .success)
                didWriteFiles([url])
            } catch {
                toast("Couldn't save the frame: \(error.localizedDescription)", .error)
            }
        }
    }

    /// Copy Frame: the frame at `seconds`, full resolution, to the clipboard (PNG + TIFF).
    func copyFrame(of video: URL, at seconds: Double) {
        guard !isSavingFrame else { return }
        isSavingFrame = true
        Task {
            defer { isSavingFrame = false }
            do {
                let frame = try await MediaFrameExtractor.frame(at: seconds, url: video)
                let image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([image])
                toast("Copied frame at \(MediaTimeMath.displayTimecode(seconds))", .success)
            } catch {
                toast("Couldn't copy the frame: \(error.localizedDescription)", .error)
            }
        }
    }

    /// Save Frame Strip…: a contact strip of N evenly spaced frames (save panel).
    func saveFrameStrip(of video: URL, displayName: String? = nil) {
        guard !isSavingFrame else { return }
        let name = displayName ?? video.lastPathComponent
        let panel = NSSavePanel()
        panel.title = "Save Frame Strip"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png, .jpeg]
        panel.directoryURL = video.deletingLastPathComponent()
        panel.nameFieldStringValue = MediaExportNaming.stripFileName(videoName: name, fileExtension: "png")
        let accessory = FormatAccessory(panel: panel, frameCounts: [4, 6, 8, 12, 16, 24], defaultCount: 8)
        panel.accessoryView = accessory.view
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format = MediaImageFormat(fileExtension: url.pathExtension)
        let count = accessory.selectedCount

        isSavingFrame = true
        Task {
            defer { isSavingFrame = false }
            do {
                let info = try await MediaFrameExtractor.info(for: video)
                guard info.hasVideo else { throw MediaToolError.noVideoTrack }
                let times = MediaTimeMath.stripTimes(duration: info.duration, count: count)
                let frames = try await MediaFrameExtractor.frames(at: times, url: video, maxPixelSize: 640)
                let pairs = zip(frames, times).compactMap { frame, time in frame.map { (image: $0, seconds: time) } }
                guard !pairs.isEmpty else { throw MediaToolError.frameUnavailable }
                let columns = count <= 6 ? count : (count <= 12 ? 4 : 6)
                try await Task.detached(priority: .userInitiated) {
                    guard let strip = MediaStripRenderer.contactStrip(frames: pairs, columns: columns) else {
                        throw MediaToolError.writeFailed(url.lastPathComponent)
                    }
                    try MediaImageWriter.write(strip, to: url, format: format)
                }.value
                toast("Saved \(url.lastPathComponent)", .success)
                didWriteFiles([url])
            } catch {
                toast("Couldn't save the strip: \(error.localizedDescription)", .error)
            }
        }
    }

    /// Save Middle Frame: a PNG of each video's midpoint, next to the video
    /// (`<video> @ 00m05s.png`, numbered if taken). No panel; never overwrites.
    func saveMiddleFrames(of videos: [URL]) {
        let videos = videos.filter { FileHelpers.isVideoFile($0.lastPathComponent) }
        guard !videos.isEmpty, !isSavingFrame else { return }
        isSavingFrame = true
        Task {
            defer { isSavingFrame = false }
            var written: [URL] = []
            var failures = 0
            for video in videos {
                if Task.isCancelled { break }
                do {
                    let info = try await MediaFrameExtractor.info(for: video)
                    guard info.hasVideo else { throw MediaToolError.noVideoTrack }
                    let time = MediaFrameExtractor.middleTime(duration: info.duration)
                    let frame = try await MediaFrameExtractor.frame(at: time, url: video)
                    let name = MediaExportNaming.frameFileName(videoName: video.lastPathComponent, seconds: time, fileExtension: "png")
                    let destination = MediaExportNaming.uniqueURL(for: name, in: video.deletingLastPathComponent(), avoiding: video)
                    try await Task.detached(priority: .userInitiated) {
                        try MediaImageWriter.write(frame, to: destination, format: .png)
                    }.value
                    written.append(destination)
                } catch {
                    failures += 1
                }
            }
            if written.count == 1, failures == 0 {
                toast("Saved \(written[0].lastPathComponent)", .success)
            } else if !written.isEmpty {
                toast("Saved \(written.count) frames" + (failures > 0 ? " (\(failures) failed)" : ""), failures > 0 ? .info : .success)
            } else {
                toast("Couldn't read a frame from \(videos.count == 1 ? "the video" : "these videos")", .error)
            }
            if !written.isEmpty { didWriteFiles(written) }
        }
    }
}

// MARK: - Save panel accessory

/// Format (PNG / JPEG) and, for strips, frame-count pop-ups under a save panel. Choosing a
/// format rewrites the name's extension.
@MainActor
private final class FormatAccessory: NSObject {
    let view: NSView
    private weak var panel: NSSavePanel?
    private let formatPopup = NSPopUpButton()
    private let countPopup = NSPopUpButton()
    private let counts: [Int]

    var selectedCount: Int {
        counts.indices.contains(countPopup.indexOfSelectedItem) ? counts[countPopup.indexOfSelectedItem] : (counts.first ?? 8)
    }

    init(panel: NSSavePanel, frameCounts: [Int] = [], defaultCount: Int = 8) {
        self.panel = panel
        counts = frameCounts
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = stack
        super.init()

        let formatLabel = NSTextField(labelWithString: "Format:")
        formatPopup.addItems(withTitles: MediaImageFormat.allCases.map(\.title))
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        stack.addArrangedSubview(formatLabel)
        stack.addArrangedSubview(formatPopup)

        if !frameCounts.isEmpty {
            let countLabel = NSTextField(labelWithString: "Frames:")
            countPopup.addItems(withTitles: frameCounts.map(String.init))
            countPopup.selectItem(at: frameCounts.firstIndex(of: defaultCount) ?? 0)
            stack.addArrangedSubview(countLabel)
            stack.addArrangedSubview(countPopup)
        }
        objc_setAssociatedObject(panel, &FormatAccessory.associationKey, self, .OBJC_ASSOCIATION_RETAIN)
    }

    nonisolated(unsafe) private static var associationKey: UInt8 = 0

    @objc private func formatChanged() {
        guard let panel else { return }
        let format = MediaImageFormat.allCases[max(formatPopup.indexOfSelectedItem, 0)]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
    }
}
