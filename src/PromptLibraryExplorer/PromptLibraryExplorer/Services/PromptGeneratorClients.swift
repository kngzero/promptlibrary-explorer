import Foundation

// MARK: - Send to generator: transport, settings, ComfyUI and A1111/Forge clients
//
// Network rules: requests go only to the base URLs the user typed in
// Settings ▸ Generators, only when the user runs an action (never
// automatically), always with a timeout. Every request goes through
// `PromptHTTPTransport`, so tests use a mock and never touch the network.

protocol PromptHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionPromptTransport: PromptHTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GeneratorError.badResponse("Not an HTTP response") }
        return (data, http)
    }
}

enum GeneratorKind: String, CaseIterable, Identifiable, Sendable {
    case comfyUI
    case a1111

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comfyUI: return "ComfyUI"
        case .a1111: return "Automatic1111 / Forge"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .comfyUI: return "http://127.0.0.1:8188"
        case .a1111: return "http://127.0.0.1:7860"
        }
    }
}

enum GeneratorError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case http(status: Int, message: String)
    case unreachable(String)
    case badResponse(String)
    case noAPIGraph
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(url):
            return "“\(url)” isn't a valid http:// or https:// address. Check Settings ▸ Generators."
        case let .http(status, message):
            return message.isEmpty ? "The server answered with HTTP \(status)." : "HTTP \(status): \(message)"
        case let .unreachable(detail):
            return "Couldn't reach the server (\(detail)). Is it running, and is its API enabled?"
        case let .badResponse(detail):
            return "Unexpected response: \(detail)"
        case .noAPIGraph:
            return "This file has only a ComfyUI UI workflow, which can't be queued directly. Load it in ComfyUI (Copy Workflow JSON) and queue it there."
        case .cancelled:
            return "Cancelled."
        }
    }
}

// MARK: - Settings

/// Base URLs and A1111 options (Settings ▸ Generators). UserDefaults injectable for tests.
@MainActor @Observable
final class GeneratorSettings {
    static let shared = GeneratorSettings()

    static let comfyURLKey = "generators.comfyUI.baseURL"
    static let a1111URLKey = "generators.a1111.baseURL"
    static let a1111UseModelKey = "generators.a1111.useFileModel"

    var comfyBaseURL: String { didSet { defaults.set(comfyBaseURL, forKey: Self.comfyURLKey) } }
    var a1111BaseURL: String { didSet { defaults.set(a1111BaseURL, forKey: Self.a1111URLKey) } }
    /// Ask A1111 to switch to the file's checkpoint for the request (restored afterwards).
    var a1111UseFileModel: Bool { didSet { defaults.set(a1111UseFileModel, forKey: Self.a1111UseModelKey) } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        comfyBaseURL = defaults.string(forKey: Self.comfyURLKey) ?? GeneratorKind.comfyUI.defaultBaseURL
        a1111BaseURL = defaults.string(forKey: Self.a1111URLKey) ?? GeneratorKind.a1111.defaultBaseURL
        a1111UseFileModel = defaults.object(forKey: Self.a1111UseModelKey) as? Bool ?? false
    }

    func baseURL(for kind: GeneratorKind) -> String {
        switch kind {
        case .comfyUI: return comfyBaseURL
        case .a1111: return a1111BaseURL
        }
    }
}

enum GeneratorEndpoint {
    /// `base` + `path`, where base must be an http(s) URL with a host.
    static func url(base: String, path: String, query: [URLQueryItem] = []) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { throw GeneratorError.invalidBaseURL(trimmed) }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + (path.hasPrefix("/") ? path : "/" + path)
        components.queryItems = query.isEmpty ? nil : query
        components.fragment = nil
        guard let url = components.url else { throw GeneratorError.invalidBaseURL(trimmed) }
        return url
    }
}

/// Shared request plumbing: JSON bodies, timeouts, status checks, readable errors.
struct GeneratorHTTP: Sendable {
    let baseURL: String
    let transport: PromptHTTPTransport

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Data? = nil, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: try GeneratorEndpoint.url(base: baseURL, path: path, query: query))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.httpBody = json
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw GeneratorError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw GeneratorError.cancelled
        } catch let error as URLError {
            throw GeneratorError.unreachable(error.localizedDescription)
        } catch let error as GeneratorError {
            throw error
        } catch {
            throw GeneratorError.unreachable(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw GeneratorError.http(status: response.statusCode, message: Self.errorMessage(from: data))
        }
        return data
    }

    /// A short message from a JSON error body (`error.message`, `detail`, `error`) or plain text.
    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                var text = message
                if let details = error["details"] as? String, !details.isEmpty { text += " — " + details }
                return String(text.prefix(300))
            }
            for key in ["detail", "error", "errors", "message"] {
                if let message = object[key] as? String { return String(message.prefix(300)) }
            }
        }
        return String((String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }
}

// MARK: - ComfyUI

struct ComfyUIClient: Sendable {
    let http: GeneratorHTTP

    init(baseURL: String, transport: PromptHTTPTransport = URLSessionPromptTransport()) {
        http = GeneratorHTTP(baseURL: baseURL, transport: transport)
    }

    /// `GET /system_stats`; returns a one-line description of the server.
    func testConnection() async throws -> String {
        let data = try await http.send(try http.request("GET", "/system_stats", timeout: 5))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeneratorError.badResponse("/system_stats didn't return JSON — is this a ComfyUI server?")
        }
        let system = object["system"] as? [String: Any]
        let version = system?["comfyui_version"] as? String
        let devices = (object["devices"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        var text = "Connected to ComfyUI"
        if let version { text += " \(version)" }
        if let device = devices.first { text += " · \(device)" }
        return text
    }

    /// `POST /prompt`; returns the queued prompt id.
    func queue(graph: PromptComfyGraph.Graph, clientID: String = UUID().uuidString) async throws -> String {
        let body = try PromptComfyGraph.requestBody(graph: graph, clientID: clientID)
        let data = try await http.send(try http.request("POST", "/prompt", json: body, timeout: 30))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeneratorError.badResponse("/prompt didn't return JSON")
        }
        if let errors = object["node_errors"] as? [String: Any], !errors.isEmpty {
            throw GeneratorError.http(status: 400, message: "ComfyUI rejected nodes \(errors.keys.sorted().joined(separator: ", "))")
        }
        guard let id = object["prompt_id"] as? String else {
            throw GeneratorError.badResponse("no prompt_id in the reply")
        }
        return id
    }
}

// MARK: - Automatic1111 / Forge

struct A1111Txt2ImgRequest: Codable, Equatable, Sendable {
    var prompt: String
    var negative_prompt: String
    var steps: Int
    var cfg_scale: Double
    var sampler_name: String?
    var scheduler: String?
    var seed: Int64
    var width: Int
    var height: Int
    var batch_size: Int = 1
    var n_iter: Int = 1
    var override_settings: [String: String]?
    var override_settings_restore_afterwards: Bool?
    var send_images: Bool = true
    var save_images: Bool = false
}

struct A1111Progress: Equatable, Sendable {
    /// 0…1.
    let fraction: Double
    let etaSeconds: Double?
    let step: Int?
    let totalSteps: Int?
}

enum PromptA1111 {
    static let outputFolderName = "A1111 Output"

    /// txt2img body from a prompt and generation parameters. Missing values
    /// fall back to A1111's usual defaults (20 steps, CFG 7, random seed, 512²).
    static func request(
        prompt: String,
        negative: String,
        parameters: GenerationParameters,
        randomSeed: Bool = false,
        useModel: Bool = false
    ) -> A1111Txt2ImgRequest {
        let steps = parameters.steps.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { min(max($0, 1), 150) } ?? 20
        let cfg = parameters.cfg.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { min(max($0, 1), 30) } ?? 7
        let seed: Int64 = randomSeed ? -1 : (parameters.seed.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? -1)
        let (sampler, scheduler) = samplerAndScheduler(parameters.sampler)
        var model: [String: String]?
        if useModel, let name = parameters.model?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            model = ["sd_model_checkpoint": name]
        }
        return A1111Txt2ImgRequest(
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            negative_prompt: negative.trimmingCharacters(in: .whitespacesAndNewlines),
            steps: steps,
            cfg_scale: cfg,
            sampler_name: sampler,
            scheduler: scheduler,
            seed: seed,
            width: dimension(parameters.width),
            height: dimension(parameters.height),
            override_settings: model,
            override_settings_restore_afterwards: model == nil ? nil : true
        )
    }

    /// Multiple of 8 within 64…2048 (A1111's own rounding), 512 when unknown.
    static func dimension(_ value: Int?) -> Int {
        guard let value, value > 0 else { return 512 }
        let clamped = min(max(value, 64), 2048)
        return (clamped / 8) * 8
    }

    /// ComfyUI sampler / scheduler names → A1111 names; A1111 names pass through.
    /// "DPM++ 2M Karras" stays one name (older A1111 reads it; newer splits it itself).
    static func samplerAndScheduler(_ raw: String?) -> (String?, String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return (nil, nil) }
        let comfy: [String: String] = [
            "euler": "Euler", "euler_ancestral": "Euler a", "heun": "Heun", "dpm_2": "DPM2", "dpm_2_ancestral": "DPM2 a",
            "lms": "LMS", "dpm_fast": "DPM fast", "dpm_adaptive": "DPM adaptive", "dpmpp_2s_ancestral": "DPM++ 2S a",
            "dpmpp_sde": "DPM++ SDE", "dpmpp_2m": "DPM++ 2M", "dpmpp_2m_sde": "DPM++ 2M SDE", "dpmpp_3m_sde": "DPM++ 3M SDE",
            "ddim": "DDIM", "uni_pc": "UniPC", "lcm": "LCM", "restart": "Restart",
        ]
        let key = raw.lowercased()
        if let mapped = comfy[key] { return (mapped, nil) }
        // "dpmpp_2m karras" / "dpmpp_2m_karras" style.
        for scheduler in ["karras", "exponential", "sgm_uniform"] where key.hasSuffix(scheduler) {
            let base = key.dropLast(scheduler.count).trimmingCharacters(in: CharacterSet(charactersIn: " _"))
            if let mapped = comfy[base] { return (mapped, scheduler == "karras" ? "Karras" : scheduler == "exponential" ? "Exponential" : "SGM Uniform") }
        }
        return (raw, nil)
    }

    /// Decoded image bytes from a txt2img reply (`images`: base64, optional data-URL prefix).
    static func decodeImages(from data: Data) throws -> [Data] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeneratorError.badResponse("txt2img didn't return JSON")
        }
        guard let images = object["images"] as? [String] else {
            throw GeneratorError.badResponse("no images in the reply")
        }
        return images.compactMap { string in
            let payload = string.range(of: "base64,").map { String(string[$0.upperBound...]) } ?? string
            return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        }
    }

    static func progress(from data: Data) -> A1111Progress? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fraction = (object["progress"] as? NSNumber)?.doubleValue
        else { return nil }
        let state = object["state"] as? [String: Any]
        return A1111Progress(
            fraction: min(max(fraction, 0), 1),
            etaSeconds: (object["eta_relative"] as? NSNumber)?.doubleValue,
            step: (state?["sampling_step"] as? NSNumber)?.intValue,
            totalSteps: (state?["sampling_steps"] as? NSNumber)?.intValue
        )
    }

    /// Default output folder: "A1111 Output" beside the source file.
    static func defaultOutputFolder(forSource source: URL) -> URL {
        source.deletingLastPathComponent().appendingPathComponent(outputFolderName, isDirectory: true)
    }

    /// `<base>.<ext>`, or `<base> 2.<ext>`, `<base> 3.<ext>`… — never an existing file.
    static func uniqueURL(in folder: URL, baseName: String, pathExtension: String, fileManager: FileManager = .default) -> URL {
        let safe = baseName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var candidate = folder.appendingPathComponent(safe).appendingPathExtension(pathExtension)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(safe) \(counter)").appendingPathExtension(pathExtension)
            counter += 1
        }
        return candidate
    }

    /// Writes each image into `folder` (created if needed) without overwriting anything.
    static func save(images: [Data], to folder: URL, baseName: String, fileManager: FileManager = .default) throws -> [URL] {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved: [URL] = []
        for image in images {
            let ext = image.starts(with: [0xFF, 0xD8]) ? "jpg" : (image.starts(with: Array("RIFF".utf8)) ? "webp" : "png")
            let url = uniqueURL(in: folder, baseName: baseName, pathExtension: ext, fileManager: fileManager)
            // withoutOverwriting: a file that appeared since the check is never replaced.
            try image.write(to: url, options: [.withoutOverwriting])
            saved.append(url)
        }
        return saved
    }
}

struct A1111Client: Sendable {
    let http: GeneratorHTTP

    init(baseURL: String, transport: PromptHTTPTransport = URLSessionPromptTransport()) {
        http = GeneratorHTTP(baseURL: baseURL, transport: transport)
    }

    /// `GET /sdapi/v1/options` (needs the server started with --api).
    func testConnection() async throws -> String {
        let data = try await http.send(try http.request("GET", "/sdapi/v1/options", timeout: 5))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeneratorError.badResponse("/sdapi/v1/options didn't return JSON — is the API enabled (--api)?")
        }
        if let model = object["sd_model_checkpoint"] as? String, !model.isEmpty {
            return "Connected · model \(model)"
        }
        return "Connected"
    }

    func txt2img(_ body: A1111Txt2ImgRequest) async throws -> [Data] {
        let json = try JSONEncoder().encode(body)
        let data = try await http.send(try http.request("POST", "/sdapi/v1/txt2img", json: json, timeout: 600))
        return try PromptA1111.decodeImages(from: data)
    }

    func progress() async throws -> A1111Progress? {
        let data = try await http.send(try http.request(
            "GET", "/sdapi/v1/progress", query: [URLQueryItem(name: "skip_current_image", value: "true")], timeout: 5
        ))
        return PromptA1111.progress(from: data)
    }

    func interrupt() async throws {
        _ = try await http.send(try http.request("POST", "/sdapi/v1/interrupt", timeout: 5))
    }
}
