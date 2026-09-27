import Foundation

struct RenameTemplateContext: Sendable {
    var url: URL
    var index: Int
    var modifiedDate: Date?
    var prompt: String?
    var model: String?
    var seed: String?
    var sampler: String?
    var steps: String?
    var cfg: String?
    var width: Int?
    var height: Int?

    init(
        url: URL,
        index: Int,
        modifiedDate: Date? = nil,
        prompt: String? = nil,
        model: String? = nil,
        seed: String? = nil,
        sampler: String? = nil,
        steps: String? = nil,
        cfg: String? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.url = url
        self.index = index
        self.modifiedDate = modifiedDate
        self.prompt = prompt
        self.model = model
        self.seed = seed
        self.sampler = sampler
        self.steps = steps
        self.cfg = cfg
        self.width = width
        self.height = height
    }
}

struct RenamePlanItem: Sendable, Identifiable, Hashable {
    var id: String { source.path }
    let source: URL
    /// Full proposed file name (with extension).
    let proposedName: String
    let conflict: Bool
    let unchanged: Bool

    var destination: URL {
        source.deletingLastPathComponent().appendingPathComponent(proposedName)
    }
}

enum RenameTemplateService {
    static let tokens: [(token: String, description: String)] = [
        ("{name}", "Original file name without extension"),
        ("{ext}", "Original extension (appended automatically when omitted)"),
        ("{date}", "Modified date, yyyy-MM-dd"),
        ("{date:FORMAT}", "Modified date in a custom format, e.g. {date:yyyyMMdd}"),
        ("{time}", "Modified time, HH-mm-ss"),
        ("{model}", "Model / checkpoint name"),
        ("{seed}", "Seed"),
        ("{sampler}", "Sampler"),
        ("{steps}", "Steps"),
        ("{cfg}", "CFG scale"),
        ("{width}", "Width in pixels"),
        ("{height}", "Height in pixels"),
        ("{prompt}", "First 60 characters of the prompt"),
        ("{prompt:N}", "First N characters of the prompt, cut at a word"),
        ("{counter}", "Position in the selection, starting at 1"),
        ("{counter:N}", "Counter zero-padded to N digits, e.g. {counter:3} → 001"),
    ]

    static let maxBaseNameLength = 180
    static let defaultPromptLength = 60

    private static let tokenPattern = try! NSRegularExpression(pattern: #"\{([A-Za-z]+)(?::([^{}]*))?\}"#)

    /// Renders a template into a full, sanitized file name (including extension).
    static func render(template: String, context: RenameTemplateContext) -> String {
        let originalName = context.url.lastPathComponent
        let originalExt = context.url.pathExtension
        let originalBase = originalExt.isEmpty ? originalName : String(originalName.dropLast(originalExt.count + 1))

        let hasExtToken = template.range(of: "{ext}", options: .caseInsensitive) != nil
        let extPlaceholder = "\u{E000}EXT\u{E000}"

        var output = ""
        let ns = template as NSString
        var cursor = 0
        for match in tokenPattern.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let token = ns.substring(with: match.range(at: 1)).lowercased()
            let argument: String? = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
            if token == "ext" {
                output += extPlaceholder
            } else if let value = value(for: token, argument: argument, context: context, originalBase: originalBase) {
                output += value
            } else {
                output += ns.substring(with: match.range)
            }
        }
        output += ns.substring(from: cursor)

        var base: String
        var ext: String
        if hasExtToken {
            // Everything from the last {ext} occurrence onwards (minus a leading dot) forms the extension.
            if let range = output.range(of: extPlaceholder, options: .backwards) {
                var head = String(output[..<range.lowerBound])
                let tail = String(output[range.upperBound...]).replacingOccurrences(of: extPlaceholder, with: originalExt)
                if head.hasSuffix(".") { head.removeLast() }
                base = head.replacingOccurrences(of: extPlaceholder, with: originalExt)
                ext = originalExt + tail
            } else {
                base = output
                ext = originalExt
            }
        } else {
            base = output
            ext = originalExt
        }

        base = sanitize(base)
        ext = sanitize(ext).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if base.isEmpty { base = sanitize(originalBase) }
        if base.isEmpty { base = "Untitled" }
        if base.count > maxBaseNameLength {
            base = String(base.prefix(maxBaseNameLength)).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Plans a batch rename: renders every item, marks unchanged names, and resolves collisions
    /// (within the batch and against files already in each destination folder) by appending " 2", " 3"….
    static func plan(template: String, items: [RenameTemplateContext]) -> [RenamePlanItem] {
        let rendered = items.map { render(template: template, context: $0) }
        let changing = zip(items, rendered).map { $0.url.lastPathComponent != $1 }

        // Names that will remain occupied in each folder, keyed case-insensitively (APFS default).
        var takenByFolder: [String: Set<String>] = [:]
        var leavingByFolder: [String: Set<String>] = [:]
        for (item, isChanging) in zip(items, changing) {
            let folder = item.url.deletingLastPathComponent().path
            if takenByFolder[folder] == nil {
                let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                takenByFolder[folder] = Set(existing.map { $0.lowercased() })
            }
            if isChanging {
                leavingByFolder[folder, default: []].insert(item.url.lastPathComponent.lowercased())
            }
        }
        for (folder, leaving) in leavingByFolder {
            takenByFolder[folder]?.subtract(leaving)
        }
        // Items keeping their name still occupy it.
        for (item, isChanging) in zip(items, changing) where !isChanging {
            takenByFolder[item.url.deletingLastPathComponent().path, default: []].insert(item.url.lastPathComponent.lowercased())
        }

        var result: [RenamePlanItem] = []
        result.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let current = item.url.lastPathComponent
            let proposed = rendered[index]
            if !changing[index] {
                result.append(RenamePlanItem(source: item.url, proposedName: current, conflict: false, unchanged: true))
                continue
            }
            let folder = item.url.deletingLastPathComponent().path
            var taken = takenByFolder[folder] ?? []
            var resolved: String?
            if !taken.contains(proposed.lowercased()) {
                resolved = proposed
            } else {
                let ext = (proposed as NSString).pathExtension
                let base = ext.isEmpty ? proposed : String(proposed.dropLast(ext.count + 1))
                for n in 2...9999 {
                    let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                    if !taken.contains(candidate.lowercased()) {
                        resolved = candidate
                        break
                    }
                }
            }
            if let resolved {
                taken.insert(resolved.lowercased())
                takenByFolder[folder] = taken
                result.append(RenamePlanItem(
                    source: item.url,
                    proposedName: resolved,
                    conflict: false,
                    unchanged: resolved == current
                ))
            } else {
                result.append(RenamePlanItem(source: item.url, proposedName: proposed, conflict: true, unchanged: false))
            }
        }
        return result
    }

    // MARK: - Tokens

    private static func value(for token: String, argument: String?, context: RenameTemplateContext, originalBase: String) -> String? {
        switch token {
        case "name":
            return originalBase
        case "date":
            let format = (argument?.isEmpty == false) ? argument! : "yyyy-MM-dd"
            return formatted(context.modifiedDate ?? Date(), format: format)
        case "time":
            let format = (argument?.isEmpty == false) ? argument! : "HH-mm-ss"
            return formatted(context.modifiedDate ?? Date(), format: format)
        case "model":
            return context.model.map(cleanModelName) ?? ""
        case "seed":
            return context.seed ?? ""
        case "sampler":
            return context.sampler ?? ""
        case "steps":
            return context.steps ?? ""
        case "cfg":
            return context.cfg ?? ""
        case "width":
            return context.width.map(String.init) ?? ""
        case "height":
            return context.height.map(String.init) ?? ""
        case "prompt":
            let length = argument.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? defaultPromptLength
            return truncatedAtWord(context.prompt ?? "", limit: max(1, length))
        case "counter":
            let number = context.index + 1
            if let width = argument.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), width > 0 {
                let digits = String(number)
                return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
            }
            return String(number)
        default:
            return nil
        }
    }

    private static func formatted(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// "models/sd_xl_base_1.0.safetensors" → "sd_xl_base_1.0"
    private static func cleanModelName(_ model: String) -> String {
        var name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: slash)...])
        }
        for ext in [".safetensors", ".ckpt", ".pt", ".pth", ".bin", ".gguf", ".sft"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
            break
        }
        if name == "N/A" { return "" }
        return name
    }

    private static func truncatedAtWord(_ text: String, limit: Int) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let prefix = String(collapsed.prefix(limit))
        let nextIndex = collapsed.index(collapsed.startIndex, offsetBy: limit)
        if collapsed[nextIndex] == " " { return prefix }
        if let lastSpace = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: lastSpace) > 0 {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: CharacterSet(charactersIn: ",;.- "))
        }
        return prefix
    }

    /// Removes path separators, colons, control characters and newlines; collapses whitespace;
    /// trims leading/trailing dots and spaces.
    static func sanitize(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" {
                scalars.append("-")
            } else if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) || scalar == "\u{E000}" {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
}
