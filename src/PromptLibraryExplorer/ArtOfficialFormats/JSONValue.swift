import Foundation

/// Lenient accessors over `JSONSerialization` output. JSONSerialization keeps each
/// string as a single NSString (bridged lazily to `String`), so a 50 MB base64 asset
/// exists once in memory and is never decoded until asked for.
typealias JSONObject = [String: Any]

enum JSON {
    static func parseObject(_ data: Data) -> JSONObject? {
        guard !data.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return obj as? JSONObject
    }

    /// First present key (supports snake_case / camelCase aliases).
    static func raw(_ obj: JSONObject?, _ keys: [String]) -> Any? {
        guard let obj else { return nil }
        for key in keys {
            if let v = obj[key], !(v is NSNull) { return v }
        }
        return nil
    }

    static func string(_ obj: JSONObject?, _ keys: String...) -> String? {
        switch raw(obj, keys) {
        case let s as String: return s
        case let n as NSNumber: return isBool(n) ? nil : n.stringValue
        default: return nil
        }
    }

    static func nonEmptyString(_ obj: JSONObject?, _ keys: String...) -> String? {
        let v: String?
        switch raw(obj, keys) {
        case let s as String: v = s
        case let n as NSNumber: v = isBool(n) ? nil : n.stringValue
        default: v = nil
        }
        guard let t = v?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func double(_ obj: JSONObject?, _ keys: String...) -> Double? {
        switch raw(obj, keys) {
        case let n as NSNumber:
            if isBool(n) { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            guard let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite else { return nil }
            return d
        default: return nil
        }
    }

    static func int(_ obj: JSONObject?, _ keys: String...) -> Int? {
        let d: Double?
        switch raw(obj, keys) {
        case let n as NSNumber: d = isBool(n) ? nil : n.doubleValue
        case let s as String: d = Double(s.trimmingCharacters(in: .whitespaces))
        default: d = nil
        }
        guard let d, d.isFinite, abs(d) < 1e12 else { return nil }
        return Int(d.rounded())
    }

    static func bool(_ obj: JSONObject?, _ keys: String...) -> Bool? {
        switch raw(obj, keys) {
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    static func object(_ obj: JSONObject?, _ keys: String...) -> JSONObject? {
        raw(obj, keys) as? JSONObject
    }

    static func objects(_ obj: JSONObject?, _ keys: String...) -> [JSONObject] {
        guard let arr = raw(obj, keys) as? [Any] else { return [] }
        return arr.compactMap { $0 as? JSONObject }
    }

    static func strings(_ obj: JSONObject?, _ keys: String...) -> [String] {
        switch raw(obj, keys) {
        case let arr as [Any]:
            return arr.compactMap { v -> String? in
                if let s = v as? String { return s }
                if let n = v as? NSNumber, !isBool(n) { return n.stringValue }
                return nil
            }
        case let s as String:
            // Some CSV-derived files store tags as "a|b" or "a, b".
            return s.split(whereSeparator: { $0 == "|" || $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        default:
            return []
        }
    }

    static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    // MARK: Writing helpers

    /// JSON-escaped string literal (with quotes).
    static func quote(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    /// Serializes a JSON-compatible value (no huge payloads) to a compact string.
    static func fragment(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum Hex {
    /// Normalises "#abc", "abc", "#AABBCCDD" to "#AABBCC". nil if unparseable.
    static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let digits = value.uppercased().filter(\.isHexDigit)
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        // Reject strings that contain non-hex content other than a leading '#'.
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == digits.count else { return nil }
        switch digits.count {
        case 3:
            let c = Array(digits)
            return "#\(c[0])\(c[0])\(c[1])\(c[1])\(c[2])\(c[2])"
        case 6: return "#\(digits)"
        case 8: return "#\(digits.prefix(6))"
        default: return nil
        }
    }

    static func rgb(_ value: String?) -> (r: Double, g: Double, b: Double)? {
        guard let hex = normalize(value), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func string(r: Double, g: Double, b: Double) -> String {
        func c(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

enum MIME {
    static func fromExtension(_ ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "avif": return "image/avif"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        default: return nil
        }
    }

    static func sniff(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 4 else { return nil }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b[0] == 0xFF, b[1] == 0xD8 { return "image/jpeg" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if brand.hasPrefix("avif") { return "image/avif" }
            return "image/heic"
        }
        if (b[0] == 0x49 && b[1] == 0x49) || (b[0] == 0x4D && b[1] == 0x4D) { return "image/tiff" }
        return nil
    }
}
