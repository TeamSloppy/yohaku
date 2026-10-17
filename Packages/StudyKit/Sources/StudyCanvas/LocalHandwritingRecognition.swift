#if canImport(UIKit)
import CryptoKit
import ImageIO
import NaturalLanguage
import PencilKit
import StudyCore
import UIKit
import Vision

public enum LocalRecognitionLanguage: String, CaseIterable, Sendable {
    case japanese = "ja-JP", russian = "ru-RU", english = "en-US"
    public var recognitionLanguages: [String] { self == .english ? [rawValue] : [rawValue, "en-US"] }
}

public enum LocalRecognitionError: Error, Equatable, Sendable {
    case unsupportedSource, invalidRegion, missingAssets([String]), unavailableAssets([String])
    case invalidAsset(String), unavailableLanguage(String), renderFailed, outputLimitExceeded
    case recognitionFailed(String)
}

public struct LocalRecognitionObservation: Sendable {
    public let text: String
    public let worldRect: Rect
    /// Best-effort text language detection; nil when ambiguous. Not a Vision language assertion.
    public let language: String?
    public let confidence: Double
}

public struct LocalRecognitionOutput: Sendable {
    /// Completion of this crop's request, not a claim of whole-document OCR coverage.
    public enum State: Equatable, Sendable { case complete, empty }
    public let source: SourceContext
    public let sourceFingerprint: String
    public let snapshotFingerprint: String
    public let runFingerprint: String
    public let engineVersion: String
    public let requestedLanguage: LocalRecognitionLanguage
    public let recognitionLanguages: [String]
    public let state: State
    public let observations: [LocalRecognitionObservation]
}

public struct LocalRecognitionRaster: Sendable {
    public let pngData: Data
    public let region: Rect
    public let pixelWidth: Int
    public let pixelHeight: Int
}

/// Saved snapshot only: no session reads, saving, provider calls, or index writes.
public enum LocalHandwritingRecognition {
    public static let engineVersion = "vision-text-r3-accurate-ink-images-v1-" + ProcessInfo.processInfo.operatingSystemVersionString
    public static let maximumDimension = 2048
    public static let maximumPixels = 4_000_000
    public static let maximumObservations = 512
    public static let maximumTextCharacters = 32_768

    public static func recognize(_ snapshot: KnowledgeSourceSnapshot,
                                 language: LocalRecognitionLanguage) async throws -> LocalRecognitionOutput {
        try Task.checkCancellation()
        let cancellation = RecognitionCancellation()
        return try await withTaskCancellationHandler {
            let raster = try await render(snapshot)
            try Task.checkCancellation()
            let observations = try await Task.detached(priority: .userInitiated) {
                try perform(raster, language: language, cancellation: cancellation)
            }.value
            try Task.checkCancellation()
            let configuration = [snapshot.fingerprint, engineVersion, language.rawValue,
                                 "correction=true", "minimumTextHeight=0.008", "max=2048/4000000"].joined(separator: "|")
            let fingerprint = SHA256.hash(data: Data(configuration.utf8)).map { String(format: "%02x", $0) }.joined()
            return LocalRecognitionOutput(source: snapshot.source, sourceFingerprint: snapshot.sourceFingerprint,
                snapshotFingerprint: snapshot.fingerprint, runFingerprint: fingerprint, engineVersion: engineVersion,
                requestedLanguage: language, recognitionLanguages: language.recognitionLanguages,
                state: observations.isEmpty ? .empty : .complete, observations: observations)
        } onCancel: { cancellation.cancel() }
    }

    /// White paper with captured objects, then ink. Authored text/link cards are opt-in for agent images;
    /// OCR excludes them because they have a raw-text index. Every selected asset must be captured and decodable.
    @MainActor public static func render(_ snapshot: KnowledgeSourceSnapshot, includeTextObjects: Bool = false) throws -> LocalRecognitionRaster {
        try Task.checkCancellation()
        guard snapshot.content.kind != .markdown,
              let page = snapshot.content.pages.first(where: { $0.id == snapshot.source.pageID }),
              let region = snapshot.source.region else { throw LocalRecognitionError.unsupportedSource }
        try validate(region)
        guard snapshot.unavailableAssets.isEmpty else { throw LocalRecognitionError.unavailableAssets(snapshot.unavailableAssets) }
        guard snapshot.missingAssets.isEmpty else { throw LocalRecognitionError.missingAssets(snapshot.missingAssets) }
        let crop = region.cgRect
        let scale = min(2, Double(maximumDimension) / max(region.width, region.height),
                        sqrt(Double(maximumPixels) / (region.width * region.height)))
        // Floor prevents rounded-up dimensions from exceeding the allocation budget.
        let width = max(1, Int(floor(region.width * scale))), height = max(1, Int(floor(region.height * scale)))
        guard width <= maximumDimension, height <= maximumDimension, width * height <= maximumPixels else {
            throw LocalRecognitionError.invalidRegion
        }
        var files = Set<String>()
        if let legacy = page.drawingFile { files.insert(legacy) }
        for shard in page.shards where shard.bounds.intersects(region) { files.insert(shard.file) }
        let objects = page.objects.filter { ($0.kind == .image || includeTextObjects) && $0.frame.intersects(region) }
        let cards = objects.filter { $0.kind != .image }
        guard cards.count <= 256, cards.reduce(0, { $0 + $1.content.count }) <= 64_000, cards.allSatisfy({ object in
            let r = object.frame
            return [r.x, r.y, r.width, r.height, r.x + r.width, r.y + r.height].allSatisfy(\.isFinite)
                && r.width > 0 && r.height > 0 && object.content.count <= 32_000
        }) else { throw LocalRecognitionError.outputLimitExceeded }
        guard files.count + objects.filter({ $0.kind == .image }).count <= 256,
              snapshot.assets.values.reduce(0, { $0 + $1.count }) <= 32 * 1024 * 1024 else {
            throw LocalRecognitionError.outputLimitExceeded
        }
        let missing = files.union(objects.filter { $0.kind == .image }.map(\.content)).filter { snapshot.assets[$0] == nil }.sorted()
        guard missing.isEmpty else { throw LocalRecognitionError.missingAssets(missing) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        var rendered: UIImage?
        var renderError: Error?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            rendered = renderer.image { output in
                let context = output.cgContext
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.scaleBy(x: Double(width) / region.width, y: Double(height) / region.height)
                context.translateBy(x: -crop.minX, y: -crop.minY); context.clip(to: crop)
                do {
                    // Decode and release one bounded thumbnail or ink shard at a time.
                    for object in objects {
                        try Task.checkCancellation()
                        try autoreleasepool {
                            if object.kind == .image {
                                guard let data = snapshot.assets[object.content], let image = thumbnail(data) else {
                                    throw LocalRecognitionError.invalidAsset(object.content)
                                }
                                image.draw(in: object.frame.cgRect)
                            } else {
                                CanvasRenderer.objects([object], images: [:], context: context)
                            }
                        }
                    }
                    for file in files.sorted() {
                        try Task.checkCancellation()
                        try autoreleasepool {
                            guard let data = snapshot.assets[file], let drawing = try? PKDrawing(data: data) else {
                                throw LocalRecognitionError.invalidAsset(file)
                            }
                            guard drawing.strokes.count <= 100_000 else { throw LocalRecognitionError.outputLimitExceeded }
                            drawing.image(from: crop, scale: min(Double(width) / region.width, Double(height) / region.height)).draw(in: crop)
                        }
                    }
                } catch { renderError = error }
            }
        }
        try Task.checkCancellation()
        if let renderError { throw renderError }
        guard let png = rendered?.pngData() else { throw LocalRecognitionError.renderFailed }
        return LocalRecognitionRaster(pngData: png, region: region, pixelWidth: width, pixelHeight: height)
    }

    /// Vision boxes use a lower-left origin. Clamp finite boxes to the selected world crop.
    public static func worldRect(normalized box: CGRect, crop: Rect) throws -> Rect {
        try validate(crop)
        guard [box.origin.x, box.origin.y, box.width, box.height, box.maxX, box.maxY].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0 else { throw LocalRecognitionError.invalidRegion }
        let clipped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, !clipped.isEmpty else { throw LocalRecognitionError.invalidRegion }
        return Rect(x: crop.x + clipped.minX * crop.width, y: crop.y + (1 - clipped.maxY) * crop.height,
                    width: clipped.width * crop.width, height: clipped.height * crop.height)
    }

    private static func validate(_ crop: Rect) throws {
        guard [crop.x, crop.y, crop.width, crop.height, crop.x + crop.width, crop.y + crop.height].allSatisfy(\.isFinite),
              crop.width > 0, crop.height > 0, crop.width <= 8192, crop.height <= 8192,
              crop.width * crop.height <= 16_777_216 else { throw LocalRecognitionError.invalidRegion }
    }

    @MainActor private static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2000,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func perform(_ raster: LocalRecognitionRaster, language: LocalRecognitionLanguage,
                                cancellation: RecognitionCancellation) throws -> [LocalRecognitionObservation] {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.recognitionLanguages = language.recognitionLanguages
        request.automaticallyDetectsLanguage = false
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        try cancellation.install(request)
        defer { cancellation.clear() }
        let available: [String]
        do { available = try request.supportedRecognitionLanguages() }
        catch { try cancellation.check(); throw LocalRecognitionError.recognitionFailed(error.localizedDescription) }
        for required in language.recognitionLanguages where !available.contains(required) {
            throw LocalRecognitionError.unavailableLanguage(required)
        }
        try cancellation.check()
        do { try VNImageRequestHandler(data: raster.pngData, options: [:]).perform([request]) }
        catch { try cancellation.check(); throw LocalRecognitionError.recognitionFailed(error.localizedDescription) }
        try cancellation.check()
        let results = request.results ?? []
        guard results.count <= maximumObservations else { throw LocalRecognitionError.outputLimitExceeded }
        var observations: [LocalRecognitionObservation] = [], characters = 0
        for result in results {
            try cancellation.check()
            guard let candidate = result.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            characters += text.count
            guard characters <= maximumTextCharacters else { throw LocalRecognitionError.outputLimitExceeded }
            let detector = NLLanguageRecognizer(); detector.processString(text)
            let detected = detector.dominantLanguage?.rawValue
            observations.append(.init(text: text, worldRect: try worldRect(normalized: result.boundingBox, crop: raster.region),
                                      language: detected, confidence: Double(candidate.confidence)))
        }
        return observations
    }
}

/// Only this synchronized holder crosses executors; Vision objects stay on the worker.
private final class RecognitionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?
    private var cancelled = false
    func install(_ request: VNRecognizeTextRequest) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            self.request = request
        }
    }
    func clear() { lock.withLock { request = nil } }
    func check() throws { try lock.withLock { if cancelled { throw CancellationError() } } }
    func cancel() {
        let active = lock.withLock { cancelled = true; return request }
        active?.cancel()
    }
}
#endif
