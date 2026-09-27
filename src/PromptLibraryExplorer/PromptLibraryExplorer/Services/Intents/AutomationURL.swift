import Foundation

/// `promptlibrary://` actions, for Shortcuts' "Open URL", scripts (`open "promptlibrary://…"`)
/// and links. Only navigation — nothing reachable from a URL writes, exports or deletes
/// anything, because any web page or app can open one.
///
///     promptlibrary://open?path=/Users/me/Renders            folder → opens it as the library root
///     promptlibrary://open?path=~/Renders/image.png          file   → its folder, file selected
///     promptlibrary://reveal?path=…                          same as open
///     promptlibrary://search?q=cinematic%20portrait          Find in Library with the query
///     promptlibrary://collection?name=Portfolio              opens the collection (case-insensitive)
///
/// `promptlibrary:open?path=…` (no `//`) works too.
enum AutomationURLAction: Equatable, Sendable {
    case open(path: String)
    case search(query: String)
    case collection(name: String)
}

enum AutomationURLError: Error, Equatable, LocalizedError {
    case wrongScheme
    case unknownAction(String)
    case missingParameter(String)
    case relativePath(String)

    var errorDescription: String? {
        switch self {
        case .wrongScheme: return "Not a promptlibrary:// link."
        case .unknownAction(let action): return "Unknown PromptLibrary link action \u{201C}\(action)\u{201D}."
        case .missingParameter(let name): return "The PromptLibrary link is missing \u{201C}\(name)\u{201D}."
        case .relativePath(let path): return "\u{201C}\(path)\u{201D} isn't a full path."
        }
    }
}

enum AutomationURL {
    static let scheme = "promptlibrary"

    static func isAutomationURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// Parses a `promptlibrary:` URL. Paths may start with `~`; they are expanded and
    /// standardized. `home` is injectable for tests.
    static func parse(_ url: URL, home: String = NSHomeDirectory()) -> Result<AutomationURLAction, AutomationURLError> {
        guard isAutomationURL(url) else { return .failure(.wrongScheme) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.unknownAction(url.absoluteString))
        }
        // promptlibrary://open?… has the action as host; promptlibrary:open?… as path.
        let action = (components.host?.isEmpty == false ? components.host! : components.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let items = components.queryItems ?? []
        func value(_ names: String...) -> String? {
            for name in names {
                if let raw = items.first(where: { $0.name.lowercased() == name })?.value {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }

        switch action {
        case "open", "reveal", "show":
            guard let raw = value("path", "file", "folder") else { return .failure(.missingParameter("path")) }
            return resolvedPath(raw, home: home).map { .open(path: $0) }
        case "search", "find":
            guard let query = value("q", "query") else { return .failure(.missingParameter("q")) }
            return .success(.search(query: query))
        case "collection":
            guard let name = value("name") else { return .failure(.missingParameter("name")) }
            return .success(.collection(name: name))
        default:
            return .failure(.unknownAction(action))
        }
    }

    /// `~` / `~/x` / `file:///x` / `/x` → a standardized absolute path.
    static func resolvedPath(_ raw: String, home: String) -> Result<String, AutomationURLError> {
        var path = raw
        if path.hasPrefix("file://"), let fileURL = URL(string: path), fileURL.isFileURL {
            path = fileURL.path
        }
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        guard path.hasPrefix("/") else { return .failure(.relativePath(raw)) }
        return .success(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    /// Builders (Help, tests, "Copy Link" style uses).
    static func openURL(path: String) -> URL? {
        make("open", [URLQueryItem(name: "path", value: path)])
    }

    static func searchURL(query: String) -> URL? {
        make("search", [URLQueryItem(name: "q", value: query)])
    }

    static func collectionURL(name: String) -> URL? {
        make("collection", [URLQueryItem(name: "name", value: name)])
    }

    private static func make(_ action: String, _ items: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = action
        components.queryItems = items
        return components.url
    }
}

/// Picks the collection a `collection?name=` link means: an exact match first, then
/// case- and diacritic-insensitive.
enum AutomationCollectionMatcher {
    static func match<ID>(_ name: String, in collections: [(id: ID, name: String)]) -> ID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = collections.first(where: { $0.name == trimmed }) { return exact.id }
        let folded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return collections.first(where: {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == folded
        })?.id
    }
}
