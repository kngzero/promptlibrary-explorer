import CryptoKit
import Foundation

// MARK: - Stack detection (pure)
//
// Automatic stacks link files in one listing that are variants of each other:
//   1. same seed + same prompt (from embedded generation metadata);
//   2. name patterns in the same folder: `name_1`, `name (2)`, `name copy`, `name-upscaled`,
//      `name@2x`, `name-v2` … all reduce to `name`; counter sequences (`ComfyUI_00012_`,
//      `name_00012_`) only link when the prompts match too;
//   3. upscale lineage: the same visual signature (dHash), the same aspect ratio and a
//      larger pixel size.
// Links are unioned into components. Manual stacks win over automatic ones and excluded
// files never join an automatic stack. Nothing here ranks files for keeping or removal;
// the cover is display-only (see `StackCover`).

/// What detection knows about one listed file.
struct StackCandidate: Sendable, Hashable {
    let path: String
    var modified: Date?
    var seed: String?
    var prompt: String?
    var width: Int?
    var height: Int?
    /// Perceptual hash from the visual index (nil when not indexed yet).
    var dHash: UInt64?

    init(
        path: String, modified: Date? = nil, seed: String? = nil, prompt: String? = nil,
        width: Int? = nil, height: Int? = nil, dHash: UInt64? = nil
    ) {
        self.path = path
        self.modified = modified
        self.seed = seed
        self.prompt = prompt
        self.width = width
        self.height = height
        self.dHash = dHash
    }

    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

enum StackReason: String, Sendable, Hashable, CaseIterable {
    case manual
    case seedAndPrompt
    case namePattern
    case upscale

    var title: String {
        switch self {
        case .manual: return "stacked by you"
        case .seedAndPrompt: return "same seed and prompt"
        case .namePattern: return "matching names"
        case .upscale: return "upscale of the same image"
        }
    }
}

/// One stack in a listing.
struct FileStack: Identifiable, Hashable, Sendable {
    /// `manual-<uuid>` or `auto-<hash of the sorted members>`.
    let id: String
    /// Members, sorted by name (the listing decides display order).
    let members: [String]
    let coverPath: String
    let manualID: UUID?
    let reasons: Set<StackReason>

    var isManual: Bool { manualID != nil }
    var count: Int { members.count }
}

enum StackCover {
    /// The cover: the manual choice when it's a member, else the most recently modified
    /// member (ties: the later name). Never chosen by file size or resolution.
    static func choose(members: [String], manualCover: String?, modified: [String: Date]) -> String? {
        if let manualCover, members.contains(manualCover) { return manualCover }
        return members.max { lhs, rhs in
            let a = modified[lhs] ?? .distantPast, b = modified[rhs] ?? .distantPast
            if a != b { return a < b }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

enum StackNamePattern {
    /// Suffix words that mark a processed copy of the same image.
    static let variantWords: Set<String> = [
        "upscaled", "upscale", "upscaler", "hires", "hi-res", "highres", "hd", "enhanced",
        "sharpened", "refined", "detailed", "fixed", "retouched", "edit", "edited", "final",
        "copy", "2x", "3x", "4x", "8x", "x2", "x3", "x4", "x8",
    ]

    /// How a file name reduces for stacking.
    struct Key: Hashable, Sendable {
        let base: String
        /// True for counter sequences (`ComfyUI_00012_`): only same-prompt files link.
        let needsSamePrompt: Bool
    }

    /// The stem with variant suffixes removed, lowercased. Nil when nothing was removed
    /// (a plain name links to its variants through their key, see `detect`).
    static func key(forFileName name: String) -> Key {
        var stem = (name as NSString).deletingPathExtension
        // Counter sequences first: `prefix_00012_` / `prefix_00012` (4+ digits).
        if let counter = stem.range(of: #"^(.+?)[_-](\d{4,})_?$"#, options: .regularExpression) {
            let prefix = stem[counter].replacingOccurrences(of: #"[_-]\d{4,}_?$"#, with: "", options: .regularExpression)
            if !prefix.isEmpty {
                return Key(base: normalizedBase(prefix) + "#counter", needsSamePrompt: true)
            }
        }
        var changed = true
        while changed {
            changed = false
            for pattern in suffixPatterns {
                if let range = stem.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                   range.lowerBound > stem.startIndex
                {
                    stem.removeSubrange(range)
                    changed = true
                }
            }
        }
        return Key(base: normalizedBase(stem), needsSamePrompt: false)
    }

    private static let variantAlternation: String = variantWords
        .sorted { $0.count > $1.count }
        .map { NSRegularExpression.escapedPattern(for: $0) }
        .joined(separator: "|")

    /// Anchored at the end of the stem; applied repeatedly.
    private static let suffixPatterns: [String] = [
        #"@\d+x$"#,                                  // name@2x
        #"[ _-]+v\d{1,3}$"#,                         // name-v2, name_v3, name v2
        #"[ _-]+(\#(variantAlternation))(\s*\d{1,3})?$"#, // name-upscaled, name copy 2
        #"\s*\(\d{1,3}\)$"#,                         // name (2)
        #"[ _-]\d{1,3}$"#,                           // name_1, name-3
    ]

    private static func normalizedBase(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"[\s_\-.]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

enum StackDetector {
    struct Options: Sendable, Equatable {
        var useSeedAndPrompt = true
        var useNamePatterns = true
        var useUpscaleLineage = true
        /// dHash Hamming distance that still counts as the same picture.
        var maxHammingDistance = 4
        /// Relative aspect-ratio difference that still counts as the same shape.
        var aspectTolerance = 0.015
        /// A lineage member must be at least this much larger (by width) than another.
        var minimumUpscaleFactor = 1.2

        init() {}
    }

    /// Stacks among `candidates` (only components of two or more). Manual stacks are
    /// resolved against the candidates (members not listed are ignored); their members and
    /// `excluded` files never join automatic stacks.
    static func detect(
        candidates: [StackCandidate],
        manual: [ManualStack] = [],
        excluded: Set<String> = [],
        options: Options = Options()
    ) -> [FileStack] {
        let byPath = Dictionary(candidates.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let modified = byPath.compactMapValues(\.modified)
        var result: [FileStack] = []
        var claimed = Set<String>()

        for stack in manual {
            let members = stack.paths.filter { byPath[$0] != nil && !claimed.contains($0) }
            guard members.count >= 2 else { continue }
            claimed.formUnion(members)
            let sorted = members.sorted(by: nameOrder)
            let cover = StackCover.choose(members: sorted, manualCover: stack.coverPath, modified: modified) ?? sorted[0]
            result.append(FileStack(id: "manual-\(stack.id.uuidString)", members: sorted, coverPath: cover, manualID: stack.id, reasons: [.manual]))
        }

        let pool = candidates.filter { !claimed.contains($0.path) && !excluded.contains($0.path) }
        guard pool.count >= 2 else { return result }
        var unions = UnionFind(count: pool.count)
        var reasons = [Set<StackReason>](repeating: [], count: pool.count)
        func link(_ i: Int, _ j: Int, _ reason: StackReason) {
            unions.union(i, j)
            reasons[i].insert(reason)
            reasons[j].insert(reason)
        }

        let prompts = pool.map { normalizedPrompt($0.prompt) }

        if options.useSeedAndPrompt {
            var bySeedPrompt: [String: [Int]] = [:]
            for (index, candidate) in pool.enumerated() {
                guard let seed = normalizedSeed(candidate.seed), let prompt = prompts[index] else { continue }
                bySeedPrompt[seed + "\u{1}" + prompt, default: []].append(index)
            }
            for members in bySeedPrompt.values where members.count > 1 {
                for other in members.dropFirst() { link(members[0], other, .seedAndPrompt) }
            }
        }

        if options.useNamePatterns {
            var byKey: [String: [Int]] = [:]
            var needsPrompt: [String: Bool] = [:]
            for (index, candidate) in pool.enumerated() {
                let key = StackNamePattern.key(forFileName: candidate.name)
                guard !key.base.isEmpty else { continue }
                let groupKey = candidate.folder + "\u{1}" + key.base
                byKey[groupKey, default: []].append(index)
                needsPrompt[groupKey] = key.needsSamePrompt
            }
            for (groupKey, members) in byKey where members.count > 1 {
                if needsPrompt[groupKey] == true {
                    // Counter sequences: only files with the same (known) prompt.
                    var byPrompt: [String: [Int]] = [:]
                    for index in members { if let prompt = prompts[index] { byPrompt[prompt, default: []].append(index) } }
                    for group in byPrompt.values where group.count > 1 {
                        for other in group.dropFirst() where compatible(pool[group[0]], pool[other], prompts[group[0]], prompts[other], options) {
                            link(group[0], other, .namePattern)
                        }
                    }
                } else {
                    for (offset, i) in members.enumerated() {
                        for j in members[(offset + 1)...] where compatible(pool[i], pool[j], prompts[i], prompts[j], options) {
                            link(i, j, .namePattern)
                        }
                    }
                }
            }
        }

        if options.useUpscaleLineage {
            let hashed = pool.indices.filter { pool[$0].dHash != nil && (pool[$0].width ?? 0) > 0 && (pool[$0].height ?? 0) > 0 }
            // Aspect buckets keep this near-linear for big folders.
            var byAspect: [Int: [Int]] = [:]
            for index in hashed {
                let ratio = Double(pool[index].width!) / Double(pool[index].height!)
                byAspect[Int((ratio * 25).rounded()), default: []].append(index)
            }
            for (bucket, members) in byAspect {
                let neighbours = members + (byAspect[bucket + 1] ?? [])
                for i in members {
                    for j in neighbours where j != i && (bucket != bucketOf(pool[j]) || j > i) {
                        if isUpscalePair(pool[i], pool[j], options) { link(i, j, .upscale) }
                    }
                }
            }
        }

        var components: [Int: [Int]] = [:]
        for index in pool.indices where !reasons[index].isEmpty {
            components[unions.find(index), default: []].append(index)
        }
        for component in components.values where component.count > 1 {
            let members = component.map { pool[$0].path }.sorted(by: nameOrder)
            let cover = StackCover.choose(members: members, manualCover: nil, modified: modified) ?? members[0]
            let why = component.reduce(into: Set<StackReason>()) { $0.formUnion(reasons[$1]) }
            result.append(FileStack(id: automaticID(members), members: members, coverPath: cover, manualID: nil, reasons: why))
        }
        return result.sorted { $0.members[0].localizedStandardCompare($1.members[0]) == .orderedAscending }
    }

    static func automaticID(_ members: [String]) -> String {
        let key = members.sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return "auto-\(digest)"
    }

    // MARK: Rules

    static func normalizedPrompt(_ prompt: String?) -> String? {
        guard let prompt else { return nil }
        let value = prompt.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Nil for missing and "random" seeds (-1, 0), which say nothing about lineage.
    static func normalizedSeed(_ seed: String?) -> String? {
        guard let seed = seed?.trimmingCharacters(in: .whitespacesAndNewlines), !seed.isEmpty else { return nil }
        if ["-1", "0", "random", "randomize", "n/a"].contains(seed.lowercased()) { return nil }
        return seed
    }

    /// Name-pattern links need the files not to contradict each other: different known
    /// prompts or clearly different shapes keep them apart.
    private static func compatible(_ a: StackCandidate, _ b: StackCandidate, _ pa: String?, _ pb: String?, _ options: Options) -> Bool {
        if let pa, let pb, pa != pb { return false }
        if let ra = aspect(a), let rb = aspect(b), abs(ra - rb) / max(ra, rb) > options.aspectTolerance * 2 { return false }
        return true
    }

    static func isUpscalePair(_ a: StackCandidate, _ b: StackCandidate, _ options: Options = Options()) -> Bool {
        guard let ha = a.dHash, let hb = b.dHash, let ra = aspect(a), let rb = aspect(b),
              let wa = a.width, let wb = b.width
        else { return false }
        guard (ha ^ hb).nonzeroBitCount <= options.maxHammingDistance else { return false }
        guard abs(ra - rb) / max(ra, rb) <= options.aspectTolerance else { return false }
        let larger = Double(max(wa, wb)), smaller = Double(max(1, min(wa, wb)))
        return larger / smaller >= options.minimumUpscaleFactor
    }

    private static func aspect(_ candidate: StackCandidate) -> Double? {
        guard let w = candidate.width, let h = candidate.height, w > 0, h > 0 else { return nil }
        return Double(w) / Double(h)
    }

    private static func bucketOf(_ candidate: StackCandidate) -> Int {
        guard let ratio = aspect(candidate) else { return .min }
        return Int((ratio * 25).rounded())
    }

    private static func nameOrder(_ lhs: String, _ rhs: String) -> Bool {
        let order = (lhs as NSString).lastPathComponent.localizedStandardCompare((rhs as NSString).lastPathComponent)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs < rhs
    }
}

// MARK: - Presentation (pure)

/// How a listing looks with stacks applied.
struct StackPresentation: Sendable, Equatable {
    struct Head: Sendable, Equatable {
        let stackID: String
        /// Members that pass the current filters.
        let visibleCount: Int
        let isExpanded: Bool
        let isManual: Bool
    }

    /// Representative path (the tile standing for a stack) → its stack.
    var heads: [String: Head] = [:]
    /// Member paths shown inline because their stack is expanded (not heads).
    var expandedMembers: [String: String] = [:]

    /// Collapses `items` (already sorted and filtered): each stack with two or more
    /// visible members is shown as one representative — its cover when visible, else its
    /// first visible member — at the representative's position; an expanded stack shows
    /// its other visible members right after it, in listing order.
    static func apply<Item>(
        to items: [Item],
        path: (Item) -> String,
        stacks: [FileStack],
        expanded: Set<String>
    ) -> (items: [Item], presentation: StackPresentation) {
        guard !stacks.isEmpty, items.count > 1 else { return (items, StackPresentation()) }
        var stackOfPath: [String: Int] = [:]
        for (index, stack) in stacks.enumerated() {
            for member in stack.members where stackOfPath[member] == nil { stackOfPath[member] = index }
        }
        var visible: [Int: [Int]] = [:]   // stack index → item indices, listing order
        for (offset, item) in items.enumerated() {
            if let stack = stackOfPath[path(item)] { visible[stack, default: []].append(offset) }
        }
        var representativeOf: [Int: Int] = [:]  // stack index → item index
        for (stack, offsets) in visible where offsets.count > 1 {
            let cover = stacks[stack].coverPath
            representativeOf[stack] = offsets.first { path(items[$0]) == cover } ?? offsets[0]
        }
        guard !representativeOf.isEmpty else { return (items, StackPresentation()) }

        var presentation = StackPresentation()
        var output: [Item] = []
        output.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            guard let stack = stackOfPath[path(item)], let representative = representativeOf[stack] else {
                output.append(item)
                continue
            }
            guard offset == representative else { continue }
            let info = stacks[stack]
            let isExpanded = expanded.contains(info.id)
            let offsets = visible[stack] ?? []
            presentation.heads[path(item)] = Head(
                stackID: info.id, visibleCount: offsets.count, isExpanded: isExpanded, isManual: info.isManual
            )
            output.append(item)
            if isExpanded {
                for other in offsets where other != representative {
                    output.append(items[other])
                    presentation.expandedMembers[path(items[other])] = info.id
                }
            }
        }
        return (output, presentation)
    }
}
