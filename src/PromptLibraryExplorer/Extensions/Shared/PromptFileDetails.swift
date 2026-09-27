import Foundation

/// A label/value row shown in previews ("Model", "Aspect ratio", ...).
public struct PreviewField: Sendable, Equatable {
    public var label: String
    public var value: String
    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Generation info + prompt analysis of a `.plib` / `.aoe`, read leniently with
/// JSONSerialization (the library's `PromptFilePreview` only carries the model).
/// Mirrors the app's `PlibFile` / `AoeFile` / `GenerationInfo` / `PromptAnalysis` shapes.
public struct PromptFileDetails: Sendable, Equatable {
    public var generation: [PreviewField] = []
    public var analysis: [PreviewField] = []
    public var shortDescription: String?

    public init(generation: [PreviewField] = [], analysis: [PreviewField] = [], shortDescription: String? = nil) {
        self.generation = generation
        self.analysis = analysis
        self.shortDescription = shortDescription
    }

    private static let analysisKeys: [(label: String, keys: [String])] = [
        ("Subject", ["subject"]),
        ("Pose", ["subject_pose", "subjectPose"]),
        ("Composition", ["composition"]),
        ("Art style", ["art_style", "artStyle"]),
        ("Camera", ["camera_settings", "cameraSettings"]),
        ("Lighting", ["lighting"]),
        ("Colour palette", ["color_palette", "colorPalette"]),
        ("Mood", ["mood"]),
    ]

    public static func read(data: Data, kind: PromptFileKind) -> PromptFileDetails {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return PromptFileDetails()
        }
        var details = PromptFileDetails()
        let analysis = root["analysis"] as? [String: Any] ?? [:]
        switch kind {
        case .plib:
            let info = root["generationInfo"] as? [String: Any] ?? [:]
            if let v = string(info["model"]) { details.generation.append(.init("Model", v)) }
            if let v = string(info["aspectRatio"]), v != "N/A" { details.generation.append(.init("Aspect ratio", v)) }
            if let n = int(info["numberOfImages"]), n > 0 { details.generation.append(.init("Images generated", String(n))) }
            if let v = timestamp(info["timestamp"]) { details.generation.append(.init("Created", v)) }
        case .aoe:
            if let v = string(root["model"]) { details.generation.append(.init("Model", v)) }
            if let v = timestamp(root["timestamp"]) { details.generation.append(.init("Created", v)) }
            if let block = root["image"] as? [String: Any], let v = string(block["mimeType"]) {
                details.generation.append(.init("Image type", v))
            }
        }
        if let hint = string(root["hint"]) { details.generation.append(.init("Hint", hint)) }
        details.shortDescription = string(analysis["short_description"]) ?? string(analysis["shortDescription"])
        for entry in analysisKeys {
            if let v = entry.keys.lazy.compactMap({ string(analysis[$0]) }).first {
                details.analysis.append(.init(entry.label, v))
            }
        }
        return details
    }

    static func string(_ any: Any?) -> String? {
        guard let s = any as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func int(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// ISO strings are shown as a short date; epoch seconds / milliseconds are converted.
    static func timestamp(_ any: Any?) -> String? {
        let date: Date?
        if let n = any as? NSNumber, !(any is Bool) {
            let v = n.doubleValue
            date = v > 0 ? Date(timeIntervalSince1970: v > 10_000_000_000 ? v / 1000 : v) : nil
        } else if let s = string(any) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            date = iso.date(from: s) ?? plain.date(from: s)
            if date == nil { return s }
        } else {
            date = nil
        }
        guard let date else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return f.string(from: date)
    }
}

public enum PromptFileKind: String, Sendable {
    case plib, aoe
}
