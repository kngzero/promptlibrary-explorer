import Foundation

/// Near-duplicate prompt detection: normalized token + word-bigram sets, MinHash/LSH candidate
/// generation, exact Jaccard verification, union-find clustering.
enum PromptSimilarityService {
    private static let hashCount = 64
    private static let bands = 16
    private static let rowsPerBand = 4 // bands * rowsPerBand == hashCount

    /// Groups paths whose prompts have Jaccard similarity ≥ `threshold` (transitively).
    /// Clusters are sorted by size (desc) then by first path; paths inside a cluster are sorted.
    static func clusters(prompts: [String: String], threshold: Double = 0.8, minClusterSize: Int = 2) -> [[String]] {
        let threshold = min(max(threshold, 0), 1)
        let paths = prompts.keys.sorted()

        // 1. Collapse identical normalized prompts; each unique feature set is one "document".
        var docIndexByKey: [String: Int] = [:]
        var docFeatures: [[UInt64]] = []
        var docMembers: [[String]] = []
        for path in paths {
            guard let prompt = prompts[path] else { continue }
            let normalized = normalize(prompt)
            guard !normalized.isEmpty else { continue }
            if let existing = docIndexByKey[normalized] {
                docMembers[existing].append(path)
            } else {
                docIndexByKey[normalized] = docFeatures.count
                docFeatures.append(featureHashes(normalizedText: normalized))
                docMembers.append([path])
            }
        }

        let docCount = docFeatures.count
        var uf = UnionFind(count: docCount)

        if docCount > 1 {
            // 2. MinHash signatures.
            let seeds = (0..<hashCount).map { splitMix64(UInt64($0) &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678) }
            var signatures = [UInt64](repeating: .max, count: docCount * hashCount)
            for doc in 0..<docCount {
                let base = doc * hashCount
                for feature in docFeatures[doc] {
                    for h in 0..<hashCount {
                        let value = splitMix64(feature ^ seeds[h])
                        if value < signatures[base + h] { signatures[base + h] = value }
                    }
                }
            }

            // 3. LSH banding → candidate pairs → exact verification.
            for band in 0..<bands {
                var buckets: [UInt64: [Int]] = [:]
                for doc in 0..<docCount {
                    let base = doc * hashCount + band * rowsPerBand
                    var key: UInt64 = 0xCBF2_9CE4_8422_2325 &+ UInt64(band)
                    for r in 0..<rowsPerBand {
                        key = splitMix64(key ^ signatures[base + r])
                    }
                    buckets[key, default: []].append(doc)
                }
                for (_, docs) in buckets where docs.count > 1 {
                    for i in 0..<(docs.count - 1) {
                        let a = docs[i]
                        for j in (i + 1)..<docs.count {
                            let b = docs[j]
                            if uf.find(a) == uf.find(b) { continue }
                            if jaccard(docFeatures[a], docFeatures[b]) >= threshold {
                                uf.union(a, b)
                            }
                        }
                    }
                }
            }
        }

        // 4. Gather clusters.
        var groups: [Int: [String]] = [:]
        for doc in 0..<docCount {
            groups[uf.find(doc), default: []].append(contentsOf: docMembers[doc])
        }
        let minSize = max(1, minClusterSize)
        return groups.values
            .filter { $0.count >= minSize }
            .map { $0.sorted() }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return (lhs.first ?? "") < (rhs.first ?? "")
            }
    }

    /// Jaccard similarity of the two prompts' normalized token + bigram sets (0...1).
    static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a)
        let nb = normalize(b)
        if na.isEmpty && nb.isEmpty { return 1 }
        if na.isEmpty || nb.isEmpty { return 0 }
        if na == nb { return 1 }
        return jaccard(featureHashes(normalizedText: na), featureHashes(normalizedText: nb))
    }

    // MARK: - Normalization

    private static let loraPattern = try! NSRegularExpression(pattern: #"<[^<>]*>"#)
    private static let weightPattern = try! NSRegularExpression(pattern: #":\s*-?\d+(\.\d+)?"#)

    /// Lowercases, removes `<lora:…>` tags and `:1.2` weights, strips punctuation, collapses whitespace.
    static func normalize(_ text: String) -> String {
        var s = text.lowercased()
        let full = NSRange(s.startIndex..<s.endIndex, in: s)
        s = loraPattern.stringByReplacingMatches(in: s, range: full, withTemplate: " ")
        let full2 = NSRange(s.startIndex..<s.endIndex, in: s)
        s = weightPattern.stringByReplacingMatches(in: s, range: full2, withTemplate: " ")

        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        var lastWasSpace = true
        for scalar in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        var result = String(out)
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// Sorted, unique 64-bit hashes of tokens and word 2-shingles.
    private static func featureHashes(normalizedText: String) -> [UInt64] {
        let tokens = normalizedText.split(separator: " ")
        var set = Set<UInt64>()
        set.reserveCapacity(tokens.count * 2)
        var previous: UInt64?
        for token in tokens {
            let h = fnv1a(token.utf8, seed: 0xCBF2_9CE4_8422_2325)
            set.insert(h)
            if let previous {
                set.insert(splitMix64(previous &* 31 &+ h ^ 0xA5A5_A5A5_A5A5_A5A5))
            }
            previous = h
        }
        return set.sorted()
    }

    private static func jaccard(_ a: [UInt64], _ b: [UInt64]) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        var i = 0, j = 0, intersection = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { intersection += 1; i += 1; j += 1 }
            else if a[i] < b[j] { i += 1 }
            else { j += 1 }
        }
        let union = a.count + b.count - intersection
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    // MARK: - Hashing

    private static func fnv1a<S: Sequence>(_ bytes: S, seed: UInt64) -> UInt64 where S.Element == UInt8 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return splitMix64(hash)
    }

    private static func splitMix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private struct UnionFind {
        var parent: [Int]
        var rank: [UInt8]

        init(count: Int) {
            parent = Array(0..<count)
            rank = [UInt8](repeating: 0, count: count)
        }

        mutating func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var node = x
            while parent[node] != root {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }

        mutating func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            if rank[ra] < rank[rb] { parent[ra] = rb }
            else if rank[ra] > rank[rb] { parent[rb] = ra }
            else { parent[rb] = ra; rank[ra] += 1 }
        }
    }
}
