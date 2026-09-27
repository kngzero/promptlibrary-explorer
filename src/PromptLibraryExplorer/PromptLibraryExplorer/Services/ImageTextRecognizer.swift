import CoreGraphics
import Foundation
import ImageIO
import Vision

/// One Vision classification label as stored (identifier as Vision names it).
struct ImageLabel: Codable, Hashable, Sendable {
    let identifier: String
    let confidence: Double
}

/// What one analysis pass found in an image.
struct ImageAnalysisResult: Sendable, Equatable {
    /// Recognised lines joined by newlines; nil when text recognition didn't run.
    var text: String?
    /// Classification labels (strongest first); nil when classification didn't run.
    var labels: [ImageLabel]?
}

/// Vision text recognition (accurate, language correction on) and image classification
/// on a downsampled copy of the image. Synchronous; callers run it off the main actor.
enum ImageTextRecognizer {
    /// Long edge of the copy Vision reads. Big enough for small captions, far smaller
    /// than a full-resolution decode.
    static let maxPixelSize = 2048
    /// Observations below this are dropped (AI images are full of glyph-like noise).
    static let minimumTextConfidence: Float = 0.45
    /// Labels kept in the store; suggestions apply their own, higher threshold.
    static let storedLabelLimit = 24
    static let storedLabelFloor = 0.05

    static func analyze(url: URL, recognizeText: Bool, classify: Bool) -> ImageAnalysisResult? {
        guard recognizeText || classify, let image = loadImage(at: url, maxPixelSize: maxPixelSize) else { return nil }
        return analyze(image: image, recognizeText: recognizeText, classify: classify)
    }

    static func analyze(image: CGImage, recognizeText: Bool, classify: Bool) -> ImageAnalysisResult {
        var requests: [VNRequest] = []
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true
        if recognizeText { requests.append(textRequest) }
        let classifyRequest = VNClassifyImageRequest()
        if classify { requests.append(classifyRequest) }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform(requests)
        } catch {
            NSLog("PromptLibraryExplorer: image analysis failed: %@", error.localizedDescription)
        }

        var result = ImageAnalysisResult()
        if recognizeText {
            let lines = (textRequest.results ?? []).compactMap { observation -> (String, Float)? in
                guard let best = observation.topCandidates(1).first else { return nil }
                return (best.string, best.confidence)
            }
            result.text = cleanedText(lines)
        }
        if classify {
            let observations = (classifyRequest.results ?? []).map { ($0.identifier, $0.confidence) }
            result.labels = storedLabels(observations)
        }
        return result
    }

    /// Downsampled decode (never full resolution), orientation applied.
    static func loadImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Filtering (pure)

    /// Keeps confident lines that contain a letter or digit, trimmed, de-duplicated.
    static func cleanedText(_ lines: [(text: String, confidence: Float)]) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for (raw, confidence) in lines where confidence >= minimumTextConfidence {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard line.count >= 2,
                  line.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains),
                  seen.insert(line.lowercased()).inserted
            else { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// The strongest labels above the storage floor.
    static func storedLabels(_ observations: [(identifier: String, confidence: Float)]) -> [ImageLabel] {
        observations
            .filter { Double($0.confidence) >= storedLabelFloor }
            .sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.identifier < $1.identifier }
            .prefix(storedLabelLimit)
            .map { ImageLabel(identifier: $0.identifier, confidence: (Double($0.confidence) * 1000).rounded() / 1000) }
    }
}

/// Case- and diacritic-insensitive "every word appears" matching for recognised text.
enum ImageTextSearch {
    static func matches(_ text: String, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return false }
        return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
