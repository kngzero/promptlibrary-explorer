import Foundation
import Observation

// MARK: - Requests (each presents one sheet; see Views/Prompts/PromptSheetsHost.swift)

struct PromptLineageRequest: Identifiable {
    let id = UUID()
    let title: String
    let paths: [String]
}

struct PromptBuilderRequest: Identifiable {
    let id = UUID()
    var draft: PromptDraft
    /// File the draft started from, for the header.
    var sourceName: String?
}

enum PromptStatisticsScope: String, CaseIterable, Identifiable {
    case folder
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: return "This Folder"
        case .library: return "Whole Library"
        }
    }
}

struct PromptStatisticsRequest: Identifiable {
    let id = UUID()
    var scope: PromptStatisticsScope
}

/// What gets sent to a generator: a file's (or the builder's) prompt and parameters.
struct GeneratorSendRequest: Identifiable {
    let id = UUID()
    let kind: GeneratorKind
    var sourcePath: String?
    var sourceName: String
    var prompt: String
    var negative: String
    var parameters: GenerationParameters
    var comfyGraphJSON: String?
    var comfyWorkflowJSON: String?
    /// Output folder when there's no source file (the builder): "A1111 Output" in the open folder.
    var fallbackOutputFolder: URL?
}

// MARK: - Controller

/// Owns the prompt-workflow sheets and the generator settings. Nothing here runs
/// on its own: every network request starts from a user action.
@MainActor @Observable
final class PromptWorkflowController {
    static let shared = PromptWorkflowController()

    var lineageRequest: PromptLineageRequest?
    var builderRequest: PromptBuilderRequest?
    var statisticsRequest: PromptStatisticsRequest?
    var generatorRequest: GeneratorSendRequest?

    let settings: GeneratorSettings
    @ObservationIgnored let transport: PromptHTTPTransport

    init(settings: GeneratorSettings? = nil, transport: PromptHTTPTransport = URLSessionPromptTransport()) {
        self.settings = settings ?? .shared
        self.transport = transport
    }

    /// True while one of this controller's sheets is up (menus disable, like other modals).
    var isPresenting: Bool {
        lineageRequest != nil || builderRequest != nil || statisticsRequest != nil || generatorRequest != nil
    }

    func comfyClient() -> ComfyUIClient { ComfyUIClient(baseURL: settings.comfyBaseURL, transport: transport) }
    func a1111Client() -> A1111Client { A1111Client(baseURL: settings.a1111BaseURL, transport: transport) }

    func testConnection(_ kind: GeneratorKind) async throws -> String {
        switch kind {
        case .comfyUI: return try await comfyClient().testConnection()
        case .a1111: return try await a1111Client().testConnection()
        }
    }
}

// MARK: - Generator job (one Send to Generator sheet)

@MainActor @Observable
final class GeneratorJobModel {
    enum Phase: Equatable {
        case ready
        case running
        case finished
        case failed
    }

    let request: GeneratorSendRequest
    private(set) var phase: Phase = .ready
    private(set) var status = ""
    /// 0…1 while A1111 reports progress.
    private(set) var progress: Double?
    private(set) var errorMessage: String?
    private(set) var queuedPromptID: String?
    private(set) var savedURLs: [URL] = []

    // Options
    var randomizeSeed = false
    var editPrompt = false
    var editedPrompt: String
    var outputFolder: URL?
    var useFileModel: Bool

    /// The current positive prompt of the ComfyUI graph, when it has one.
    let graphPrompt: String?
    /// The file has a UI workflow but no API graph.
    let hasOnlyUIWorkflow: Bool

    @ObservationIgnored private let controller: PromptWorkflowController
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(request: GeneratorSendRequest, controller: PromptWorkflowController? = nil) {
        let controller = controller ?? .shared
        self.request = request
        self.controller = controller
        useFileModel = controller.settings.a1111UseFileModel
        let graph = request.comfyGraphJSON.flatMap(PromptComfyGraph.parse)
        graphPrompt = graph.flatMap(PromptComfyGraph.positivePrompt(in:))
        hasOnlyUIWorkflow = graph == nil && request.comfyWorkflowJSON != nil
        editedPrompt = request.kind == .comfyUI ? (graphPrompt ?? request.prompt) : request.prompt
        if let source = request.sourcePath {
            outputFolder = PromptA1111.defaultOutputFolder(forSource: URL(fileURLWithPath: source))
        } else {
            outputFolder = request.fallbackOutputFolder
        }
    }

    var canStart: Bool {
        guard phase != .running else { return false }
        switch request.kind {
        case .comfyUI: return request.comfyGraphJSON.flatMap(PromptComfyGraph.parse) != nil
        case .a1111: return outputFolder != nil && !editedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var serverDescription: String { controller.settings.baseURL(for: request.kind) }

    func start() {
        guard canStart else { return }
        phase = .running
        errorMessage = nil
        progress = nil
        savedURLs = []
        queuedPromptID = nil
        switch request.kind {
        case .comfyUI: startComfy()
        case .a1111: startA1111()
        }
    }

    func cancel() {
        guard phase == .running else { return }
        status = "Cancelling…"
        if request.kind == .a1111 {
            let client = controller.a1111Client()
            Task { try? await client.interrupt() }
        }
        task?.cancel()
    }

    /// Stops polling / waiting when the sheet closes (A1111 is interrupted too).
    func tearDown() {
        cancel()
        pollTask?.cancel()
    }

    // MARK: ComfyUI

    private func startComfy() {
        guard let json = request.comfyGraphJSON, let graph = PromptComfyGraph.parse(json) else {
            fail(GeneratorError.noAPIGraph)
            return
        }
        let seed = randomizeSeed ? PromptComfyGraph.randomSeed() : nil
        let prompt = editPrompt ? editedPrompt : nil
        let edit = PromptComfyGraph.edit(graph, seed: seed, positivePrompt: prompt)
        if prompt != nil, edit.promptLocations.isEmpty {
            fail(GeneratorError.badResponse("couldn't find the text encoder feeding the sampler's positive input, so the prompt can't be replaced"))
            return
        }
        status = "Queuing in ComfyUI…"
        let client = controller.comfyClient()
        let edited = edit.graph
        task = Task { [weak self] in
            do {
                let id = try await client.queue(graph: edited)
                guard let self else { return }
                self.queuedPromptID = id
                var message = "Queued in ComfyUI · prompt \(id)"
                if let seed { message += " · seed \(seed)" }
                self.status = message
                self.phase = .finished
            } catch {
                self?.fail(error)
            }
        }
    }

    // MARK: A1111 / Forge

    private func startA1111() {
        guard let folder = outputFolder else { return }
        controller.settings.a1111UseFileModel = useFileModel
        let body = PromptA1111.request(
            prompt: editedPrompt,
            negative: request.negative,
            parameters: request.parameters,
            randomSeed: randomizeSeed,
            useModel: useFileModel
        )
        let client = controller.a1111Client()
        let baseName = Self.outputBaseName(source: request.sourceName, seed: body.seed)
        status = "Generating \(body.width)×\(body.height), \(body.steps) steps…"
        progress = 0
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if let value = try? await client.progress(), let self, self.phase == .running {
                    self.progress = value.fraction
                    if let step = value.step, let total = value.totalSteps, total > 0 {
                        self.status = "Step \(step) of \(total)"
                            + (value.etaSeconds.map { $0 > 0 ? String(format: " · about %.0f s left", $0) : "" } ?? "")
                    }
                }
            }
        }
        task = Task { [weak self] in
            defer { self?.pollTask?.cancel() }
            do {
                let images = try await client.txt2img(body)
                try Task.checkCancellation()
                guard !images.isEmpty else { throw GeneratorError.badResponse("no images returned") }
                let saved = try await Task.detached(priority: .userInitiated) {
                    try PromptA1111.save(images: images, to: folder, baseName: baseName)
                }.value
                guard let self else { return }
                self.savedURLs = saved
                self.progress = 1
                self.status = saved.count == 1
                    ? "Saved \(saved[0].lastPathComponent) to \(folder.lastPathComponent)"
                    : "Saved \(saved.count) images to \(folder.lastPathComponent)"
                self.phase = .finished
            } catch {
                self?.fail(error)
            }
        }
    }

    nonisolated static func outputBaseName(source: String, seed: Int64) -> String {
        let stem = (source as NSString).deletingPathExtension
        let base = stem.isEmpty ? "A1111" : stem
        return seed >= 0 ? "\(base) a1111 \(seed)" : "\(base) a1111"
    }

    private func fail(_ error: Error) {
        pollTask?.cancel()
        if error is CancellationError || (error as? GeneratorError) == .cancelled {
            phase = .ready
            status = "Cancelled"
            progress = nil
            return
        }
        phase = .failed
        progress = nil
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        status = ""
    }
}
