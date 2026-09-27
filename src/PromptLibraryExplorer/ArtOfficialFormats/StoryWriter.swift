import Foundation

/// Input for `StoryWriter`: one project, one scene, one shot per image.
public struct StoryDraft: Sendable {
    public struct Shot: Sendable {
        /// Shot name, usually the image filename.
        public var name: String
        /// Any ImageIO-readable bytes; stored as a JPEG data URL (longest side <= 1024 px).
        public var imageData: Data?
        /// Prompt text.
        public var description: String
        public var tags: [String]
        /// Shot type tags (JSON "type"), e.g. ["WS"].
        public var types: [String]
        public var estDurationSec: Int

        public init(name: String, imageData: Data? = nil, description: String = "", tags: [String] = [],
                    types: [String] = [], estDurationSec: Int = 5) {
            self.name = name
            self.imageData = imageData
            self.description = description
            self.tags = tags
            self.types = types
            self.estDurationSec = estDurationSec
        }
    }

    public var title: String
    /// nil -> derived from the title (uppercase initials, e.g. "MY FILM" -> "MF").
    public var code: String?
    public var logline: String?
    public var aspectRatio: String
    public var sceneName: String
    public var sceneLocation: String
    public var shots: [Shot]

    public init(title: String, code: String? = nil, logline: String? = nil, aspectRatio: String = "16:9",
                sceneName: String = "Scene 1", sceneLocation: String = "", shots: [Shot] = []) {
        self.title = title
        self.code = code
        self.logline = logline
        self.aspectRatio = aspectRatio
        self.sceneName = sceneName
        self.sceneLocation = sceneLocation
        self.shots = shots
    }
}

/// Writes a `.stry` that both Story web (`normalizeLoadedState` + `LOAD_STATE`) and
/// Story for Mac (`ProjectIO.decode` with `convertFromSnakeCase` -> `restore`) import:
/// required `projects`/`scenes`/`shots` arrays, every element has an `id`, integer
/// durations/numbers, "yyyy-MM-dd" dates, `proj_`/`scn_`/`sht_` UUID ids, and the
/// optional arrays present but empty (`shotTypePresets` omitted so web keeps its defaults).
public enum StoryWriter {
    public static let maxThumbPixelSize = 1024

    public static func write(_ draft: StoryDraft, to url: URL) throws {
        try FileLoader.write(encode(draft), to: url)
    }

    public static func encode(_ draft: StoryDraft, now: Date = Date()) throws -> Data {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd"   // local time zone, matching ProjectIO
        let today = df.string(from: now)

        let projectID = "proj_" + UUID().uuidString
        let sceneID = "scn_" + UUID().uuidString
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.isEmpty ? "Untitled" : title
        let code = draft.code?.trimmingCharacters(in: .whitespaces).nonEmpty ?? derivedCode(resolvedTitle)

        var project: [String: Any] = [
            "id": projectID,
            "index": 0,
            "title": resolvedTitle,
            "code": code,
            "status": "Planning",
            "dates": ["start": today, "end": today],
            "cover_image": "",
            "aspectRatio": draft.aspectRatio.isEmpty ? "16:9" : draft.aspectRatio,
        ]
        if let logline = draft.logline?.nonEmpty { project["logline"] = logline }

        let totalDuration = draft.shots.reduce(0) { $0 + max(0, $1.estDurationSec) }
        let scene: [String: Any] = [
            "id": sceneID,
            "project_id": projectID,
            "index": 0,
            "name": draft.sceneName.isEmpty ? "Scene 1" : draft.sceneName,
            "number": 1,
            "location": draft.sceneLocation,
            "int_ext": "INT",
            "day_night": "DAY",
            "priority": 1,
            "est_duration_sec": totalDuration,
            "notes": "",
        ]

        var out = Data()
        func put(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        put("{\n  \"projects\": [\(JSON.fragment(project))],\n")
        put("  \"scenes\": [\(JSON.fragment(scene))],\n")
        put("  \"shots\": [")
        for (i, shot) in draft.shots.enumerated() {
            let dict: [String: Any] = [
                "id": "sht_" + UUID().uuidString,
                "scene_id": sceneID,
                "index": i,
                "type": shot.types,
                "name": shot.name,
                "description": shot.description,
                "detailed_notes": "",
                "est_duration_sec": max(0, shot.estDurationSec),
                "status": "Planned",
                "tags": shot.tags,
                "takes": [Any](),
                "thumb": "@@THUMB@@",
            ]
            let json = JSON.fragment(dict)
            put(i == 0 ? "\n    " : ",\n    ")
            // Splice the (potentially large) data URL in without re-serialising it.
            let parts = json.components(separatedBy: "\"@@THUMB@@\"")
            put(parts[0])
            if let data = shot.imageData, let jpeg = ImageCodec.jpeg(from: data, maxPixelSize: maxThumbPixelSize) {
                put("\"data:image/jpeg;base64,")
                out.append(jpeg.base64EncodedData())
                put("\"")
            } else {
                put("\"\"")
            }
            if parts.count > 1 { put(parts[1...].joined(separator: "\"\"")) }
        }
        put(draft.shots.isEmpty ? "],\n" : "\n  ],\n")
        for key in ["shotTemplates", "audioAssets", "assemblyClips", "assemblyComments", "asset_lists", "project_assets"] {
            put("  \"\(key)\": [],\n")
        }
        put("  \"scripts\": []\n}\n")
        return out
    }

    static func derivedCode(_ title: String) -> String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let initials = words.prefix(4).compactMap(\.first).map { String($0).uppercased() }.joined()
        return initials.isEmpty ? "PRJ" : initials
    }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
