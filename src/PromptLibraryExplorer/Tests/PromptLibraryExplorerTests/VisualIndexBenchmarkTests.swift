import XCTest
@testable import PromptLibraryExplorer

/// Performance numbers, not assertions. Run with VISUAL_BENCH=1.
final class VisualIndexBenchmarkTests: VisualIndexTestCase {
    func testBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["VISUAL_BENCH"] != nil else { throw XCTSkip("set VISUAL_BENCH=1") }
        for index in 0..<200 {
            try put(String(format: "b%03d.png", index), VisualFixture.png(VisualFixture.scene(seed: UInt64(1000 + index), width: 1024, height: 768)))
        }
        var start = Date()
        await service.indexLibrary(root: library)
        let indexSeconds = Date().timeIntervalSince(start)
        print(String(format: "BENCH signatures: 200 PNG 1024x768 in %.2fs = %.0f/s (%d workers)", indexSeconds, 200 / indexSeconds, VisualIndexService.workerCount))

        let real = await service.signatures(forPaths: (0..<200).map { path(String(format: "b%03d.png", $0)) })
        let prints = real.values.compactMap(\.featurePrint)
        let palettes = real.values.map(\.dominantColors)

        var rng = SplitMix64(seed: 99)
        var records: [VisualIndexRecord] = []
        let folder = library.appendingPathComponent("Synthetic").path
        for index in 0..<10_000 {
            // 1,000 clusters of 3 near-duplicates (≤ 3 bit flips) among 7,000 unrelated.
            var hash = rng.next()
            if index >= 7_000 {
                hash = records[(index - 7_000) / 3].dHash!
                for _ in 0..<(rng.next() % 4) { hash ^= 1 << (rng.next() % 64) }
            }
            let printIndex = index >= 7_000 ? ((index - 7_000) / 3) % prints.count : index % prints.count
            records.append(VisualIndexRecord(
                path: folder + String(format: "/s%05d.png", index), folder: folder, mtime: 0, size: 0,
                sha256: String(format: "%064x", index), dHash: hash, featurePrint: prints[printIndex],
                colors: palettes[printIndex % palettes.count], width: 100, height: 100, isVideo: false
            ))
        }
        await service.store(records)
        let scope = VisualScope.folder(URL(fileURLWithPath: folder))
        for strictness in [0.0, 0.5, 0.9] {
            start = Date()
            let sets = await service.similarSets(in: scope, strictness: strictness, includeVideos: true)
            print(String(format: "BENCH similarSets 10k strictness %.1f: %.3fs, %d sets", strictness, Date().timeIntervalSince(start), sets.count))
        }
        start = Date()
        let hits = await service.moreLikeThis(path: records[7_000].path, in: scope, limit: 100)
        print(String(format: "BENCH moreLikeThis 10k: %.3fs (%d hits)", Date().timeIntervalSince(start), hits.count))
        start = Date()
        var decodedCount = 0
        for record in records { if VisualSignatureExtractor.vector(from: record.featurePrint!) != nil { decodedCount += 1 } }
        print(String(format: "BENCH unarchive 10k prints: %.3fs (%d bytes each)", Date().timeIntervalSince(start), prints[0].count))
        start = Date()
        let colours = await service.colorMatches(palette: ["#FF0000", "#223344"], tolerance: 0.5, in: scope, limit: 100)
        print(String(format: "BENCH colorMatches 10k: %.3fs (%d hits)", Date().timeIntervalSince(start), colours.count))
    }
}
