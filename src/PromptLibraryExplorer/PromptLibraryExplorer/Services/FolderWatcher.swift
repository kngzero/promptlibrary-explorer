import CoreServices
import Foundation

/// A file-level FSEvents stream on one or more folders (recursive). Events arrive
/// on a private utility queue, already mapped to `FolderWatchEvent`s; the handler
/// hops wherever it needs to. `stop()` (or releasing the watcher) ends the stream.
final class FolderWatcher: @unchecked Sendable {
    typealias Handler = @Sendable ([FolderWatchEvent]) -> Void

    let paths: [String]
    let latency: TimeInterval

    private let handler: Handler
    private let queue = DispatchQueue(label: "com.artofficial.promptlibrary.folder-watcher", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    /// Retained by the stream (released with it), so a callback in flight never
    /// reaches a deallocated watcher.
    private final class CallbackBox {
        let handler: Handler
        init(handler: @escaping Handler) { self.handler = handler }
    }

    init(paths: [String], latency: TimeInterval = 0.5, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return stream != nil
    }

    /// Starts the stream. Returns false when FSEvents refused (e.g. no such folder).
    @discardableResult
    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { return true }
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return false }

        let box = CallbackBox(handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            FolderWatcher.callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            Unmanaged.passUnretained(box).release()
            return false
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self)
        var events: [FolderWatchEvent] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            guard let path = paths[index] as? String else { continue }
            events.append(FolderWatchEvent(path: path, flags: mapFlags(eventFlags[index])))
        }
        if !events.isEmpty { box.handler(events) }
    }

    static func mapFlags(_ raw: FSEventStreamEventFlags) -> FolderWatchEventFlags {
        func has(_ flag: Int) -> Bool { raw & FSEventStreamEventFlags(flag) != 0 }
        var flags: FolderWatchEventFlags = []
        if has(kFSEventStreamEventFlagItemCreated) { flags.insert(.created) }
        if has(kFSEventStreamEventFlagItemRemoved) { flags.insert(.removed) }
        if has(kFSEventStreamEventFlagItemRenamed) { flags.insert(.renamed) }
        if has(kFSEventStreamEventFlagItemModified) { flags.insert(.modified) }
        if has(kFSEventStreamEventFlagItemXattrMod) || has(kFSEventStreamEventFlagItemInodeMetaMod)
            || has(kFSEventStreamEventFlagItemFinderInfoMod) || has(kFSEventStreamEventFlagItemChangeOwner)
        {
            flags.insert(.metadataOnly)
        }
        if has(kFSEventStreamEventFlagItemIsFile) { flags.insert(.isFile) }
        if has(kFSEventStreamEventFlagItemIsDir) { flags.insert(.isDirectory) }
        if has(kFSEventStreamEventFlagRootChanged) { flags.insert(.rootChanged) }
        if has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagUserDropped)
            || has(kFSEventStreamEventFlagKernelDropped)
        {
            flags.insert(.mustScanSubdirectories)
        }
        if has(kFSEventStreamEventFlagMount) || has(kFSEventStreamEventFlagUnmount) { flags.insert(.volumeChanged) }
        return flags
    }
}
