import Accelerate
import Foundation

// Pure, Sendable helpers behind the visual index: OKLab colour maths, palette
// k-means, Hamming-space candidate search and union-find. No I/O here.

// MARK: - OKLab

struct OKLab: Sendable, Hashable {
    var l: Double
    var a: Double
    var b: Double

    func distance(to other: OKLab) -> Double {
        let dl = l - other.l, da = a - other.a, db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// 8-bit sRGB components (0…255) → OKLab (Björn Ottosson's matrices).
    init(red: Double, green: Double, blue: Double) {
        let r = OKLab.linear(red / 255), g = OKLab.linear(green / 255), bl = OKLab.linear(blue / 255)
        let lms0 = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl
        let lms1 = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl
        let lms2 = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl
        let l_ = cbrt(lms0), m_ = cbrt(lms1), s_ = cbrt(lms2)
        l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    }

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// `#RRGGBB`, `RRGGBB`, `#RGB` (case-insensitive, surrounding spaces ignored).
    /// Nil for anything else.
    init?(hex: String) {
        var digits: [UInt32] = []
        digits.reserveCapacity(6)
        for byte in hex.utf8 {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digits.append(UInt32(byte - UInt8(ascii: "0")))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digits.append(UInt32(byte - UInt8(ascii: "a") + 10))
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digits.append(UInt32(byte - UInt8(ascii: "A") + 10))
            case UInt8(ascii: "#"):
                guard digits.isEmpty else { return nil }
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"):
                continue
            default:
                return nil
            }
            if digits.count > 6 { return nil }
        }
        if digits.count == 3 { digits = digits.flatMap { [$0, $0] } }
        guard digits.count == 6 else { return nil }
        self.init(
            red: Double(digits[0] * 16 + digits[1]),
            green: Double(digits[2] * 16 + digits[3]),
            blue: Double(digits[4] * 16 + digits[5])
        )
    }

    /// Back to gamut-clamped 8-bit sRGB, as `#RRGGBB`.
    var hex: String {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_
        let r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        func byte(_ v: Double) -> Int { Int((OKLab.gamma(min(1, max(0, v))) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(bl))
    }

    /// Chroma (colourfulness); < ~0.03 reads as a neutral.
    var chroma: Double { (a * a + b * b).squareRoot() }

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func gamma(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}

// MARK: - Palettes

enum VisualPalette {
    /// Dominant colours of OKLab samples: k-means (k-means++ seeding with a fixed
    /// seed, so results are deterministic), near-identical clusters merged, sorted by
    /// weight (share of samples) descending.
    static func dominantColors(samples: [OKLab], k: Int = 5, iterations: Int = 12) -> [DominantColor] {
        guard !samples.isEmpty else { return [] }
        let clusterCount = min(k, samples.count)
        var rng = SplitMix64(seed: 0x5EED_C010)
        var centroids: [OKLab] = [samples[Int(rng.next() % UInt64(samples.count))]]
        var nearest = samples.map { $0.squaredDistance(to: centroids[0]) }
        while centroids.count < clusterCount {
            let total = nearest.reduce(0, +)
            guard total > 1e-12 else { break }   // every sample already sits on a centroid
            var target = Double(rng.next() % 1_000_000) / 1_000_000 * total
            var chosen = samples.count - 1
            for (index, d) in nearest.enumerated() {
                target -= d
                if target <= 0 { chosen = index; break }
            }
            let centroid = samples[chosen]
            centroids.append(centroid)
            for index in samples.indices {
                nearest[index] = min(nearest[index], samples[index].squaredDistance(to: centroid))
            }
        }

        var assignment = [Int](repeating: 0, count: samples.count)
        for iteration in 0..<iterations {
            var changed = false
            for (index, sample) in samples.enumerated() {
                var best = 0
                var bestDistance = Double.greatestFiniteMagnitude
                for (c, centroid) in centroids.enumerated() {
                    let d = sample.squaredDistance(to: centroid)
                    if d < bestDistance { bestDistance = d; best = c }
                }
                if assignment[index] != best {
                    assignment[index] = best
                    changed = true
                }
            }
            var sums = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: centroids.count)
            for (index, sample) in samples.enumerated() {
                let c = assignment[index]
                sums[c].0 += sample.l; sums[c].1 += sample.a; sums[c].2 += sample.b; sums[c].3 += 1
            }
            for c in centroids.indices where sums[c].3 > 0 {
                let n = Double(sums[c].3)
                centroids[c] = OKLab(l: sums[c].0 / n, a: sums[c].1 / n, b: sums[c].2 / n)
            }
            if !changed && iteration > 0 { break }
        }

        var counts = [Int](repeating: 0, count: centroids.count)
        for c in assignment { counts[c] += 1 }
        var clusters: [(OKLab, Int)] = zip(centroids, counts).filter { $0.1 > 0 }.map { ($0.0, $0.1) }
        clusters.sort { $0.1 > $1.1 }

        // Merge clusters that are visually the same colour into the heavier one.
        var merged: [(OKLab, Int)] = []
        for cluster in clusters {
            if let index = merged.firstIndex(where: { $0.0.distance(to: cluster.0) < 0.03 }) {
                let (c, n) = merged[index]
                let total = Double(n + cluster.1)
                merged[index] = (
                    OKLab(
                        l: (c.l * Double(n) + cluster.0.l * Double(cluster.1)) / total,
                        a: (c.a * Double(n) + cluster.0.a * Double(cluster.1)) / total,
                        b: (c.b * Double(n) + cluster.0.b * Double(cluster.1)) / total
                    ),
                    n + cluster.1
                )
            } else {
                merged.append(cluster)
            }
        }
        let total = Double(samples.count)
        return merged
            .sorted { $0.1 > $1.1 }
            .map { DominantColor(hex: $0.0.hex, weight: (Double($0.1) / total * 1000).rounded() / 1000) }
    }

    /// Cost of finding `query` in a palette: the best (distance + coverage penalty) over
    /// the dominant colours, where the penalty is `smallColorPenalty × (1 − weight)` — so
    /// an all-red image beats a half-red one, and a speck of red barely counts.
    static func cost(of query: OKLab, in palette: [(OKLab, Double)]) -> Double {
        var best = Double.greatestFiniteMagnitude
        for (colour, weight) in palette {
            let penalty = smallColorPenalty * (1 - weight)
            best = min(best, query.distance(to: colour) + penalty)
        }
        return best
    }

    static let smallColorPenalty = 0.08

    /// Mean cost of every query colour (equal weights) — the colour-search distance.
    static func matchDistance(query: [OKLab], palette: [(OKLab, Double)]) -> Double {
        guard !query.isEmpty, !palette.isEmpty else { return .greatestFiniteMagnitude }
        return query.reduce(0) { $0 + cost(of: $1, in: palette) } / Double(query.count)
    }

    /// Symmetric weighted palette distance (each colour → nearest in the other palette,
    /// weighted by its share), averaged both ways. Used to confirm near-duplicates.
    static func paletteDistance(_ lhs: [(OKLab, Double)], _ rhs: [(OKLab, Double)]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        func directed(_ a: [(OKLab, Double)], _ b: [(OKLab, Double)]) -> Double {
            var sum = 0.0, weights = 0.0
            for (colour, weight) in a {
                let d = b.reduce(Double.greatestFiniteMagnitude) { min($0, colour.distance(to: $1.0)) }
                sum += d * weight
                weights += weight
            }
            return weights > 0 ? sum / weights : 0
        }
        return (directed(lhs, rhs) + directed(rhs, lhs)) / 2
    }

    static func lab(_ colors: [DominantColor]) -> [(OKLab, Double)] {
        colors.compactMap { color in OKLab(hex: color.hex).map { ($0, color.weight) } }
    }
}

extension OKLab {
    fileprivate func squaredDistance(to other: OKLab) -> Double {
        let dl = l - other.l, da = a - other.a, db = b - other.b
        return dl * dl + da * da + db * db
    }
}

/// Tiny deterministic PRNG (k-means seeding, test fixtures).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Hamming search (multi-index hashing)

/// Finds 64-bit hashes within a Hamming radius without comparing every pair.
///
/// Multi-index hashing: the hash is split into four 16-bit chunks, each with its own
/// bucket table (CSR arrays, 65,536 buckets). By pigeonhole, two hashes within
/// distance `r` agree to within `r / 4` bits on at least one chunk, so probing every
/// chunk value within `r / 4` bit flips of the query finds every true neighbour.
/// Cost per query ≈ 4 × C(16, ≤ r/4) bucket probes plus the (few) candidates in them.
struct HammingIndex: Sendable {
    static let maxRadius = 15   // r / 4 ≤ 3 → 697 probes per chunk

    private let hashes: [UInt64]
    private var offsets: [[Int32]] = []   // 4 × 65,537
    private var items: [[Int32]] = []     // 4 × n

    init(hashes: [UInt64]) {
        self.hashes = hashes
        for chunk in 0..<4 {
            var counts = [Int32](repeating: 0, count: 65_537)
            for hash in hashes { counts[Int(Self.chunk(hash, chunk)) + 1] += 1 }
            for index in 1..<counts.count { counts[index] += counts[index - 1] }
            var cursor = counts
            var bucketItems = [Int32](repeating: 0, count: hashes.count)
            for (index, hash) in hashes.enumerated() {
                let bucket = Int(Self.chunk(hash, chunk))
                bucketItems[Int(cursor[bucket])] = Int32(index)
                cursor[bucket] += 1
            }
            offsets.append(counts)
            items.append(bucketItems)
        }
    }

    /// Caller-owned scratch for `neighbours`, reused across queries.
    struct Scratch {
        fileprivate var stamp: [UInt32]
        fileprivate var generation: UInt32 = 0
        init(count: Int) { stamp = [UInt32](repeating: 0, count: count) }
    }

    /// Calls `visit(index, distance)` once for every index whose hash is within
    /// `radius` of `hashes[query]`, excluding `query` itself.
    func neighbours(of query: Int, radius: Int, scratch: inout Scratch, visit: (Int, Int) -> Void) {
        neighbours(of: hashes[query], radius: radius, excluding: query, scratch: &scratch, visit: visit)
    }

    func neighbours(of hash: UInt64, radius: Int, excluding: Int? = nil, scratch: inout Scratch, visit: (Int, Int) -> Void) {
        let r = min(radius, Self.maxRadius)
        let masks = Self.masks[r / 4]
        scratch.generation &+= 1
        if scratch.generation == 0 {
            scratch.stamp = [UInt32](repeating: 0, count: scratch.stamp.count)
            scratch.generation = 1
        }
        let marker = scratch.generation
        if let excluding { scratch.stamp[excluding] = marker }
        for chunk in 0..<4 {
            let base = Self.chunk(hash, chunk)
            let chunkOffsets = offsets[chunk]
            let chunkItems = items[chunk]
            for mask in masks {
                let bucket = Int(base ^ mask)
                let lower = Int(chunkOffsets[bucket]), upper = Int(chunkOffsets[bucket + 1])
                guard lower < upper else { continue }
                for slot in lower..<upper {
                    let candidate = Int(chunkItems[slot])
                    if scratch.stamp[candidate] == marker { continue }
                    scratch.stamp[candidate] = marker
                    let distance = (hashes[candidate] ^ hash).nonzeroBitCount
                    if distance <= r { visit(candidate, distance) }
                }
            }
        }
    }

    private static func chunk(_ hash: UInt64, _ index: Int) -> UInt16 {
        UInt16(truncatingIfNeeded: hash >> (UInt64(index) * 16))
    }

    /// masks[k] = every UInt16 with at most k bits set (k = 0…3).
    private static let masks: [[UInt16]] = {
        var byPopcount = [[UInt16]](repeating: [], count: 4)
        for value in 0...UInt16.max {
            let bits = value.nonzeroBitCount
            if bits <= 3 { byPopcount[bits].append(value) }
        }
        var result: [[UInt16]] = []
        var accumulated: [UInt16] = []
        for k in 0..<4 {
            accumulated += byPopcount[k]
            result.append(accumulated)
        }
        return result
    }()
}

// MARK: - Union-find

struct UnionFind {
    private var parent: [Int]
    private var rank: [UInt8]

    init(count: Int) {
        parent = Array(0..<count)
        rank = [UInt8](repeating: 0, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var node = x
        while parent[node] != root { let next = parent[node]; parent[node] = root; node = next }
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

// MARK: - Feature vectors

enum VisualVectorMath {
    /// Euclidean distance — what `VNFeaturePrintObservation.computeDistance` returns
    /// for feature prints (verified in VisualIndexServiceTests).
    static func distance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .greatestFiniteMagnitude }
        var result: Float = 0
        vDSP_distancesq(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
        return result.squareRoot()
    }
}
