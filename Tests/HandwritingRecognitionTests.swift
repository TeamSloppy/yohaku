#if canImport(UIKit)
import PencilKit
import StudyCanvas
import StudyCore
import Testing
import UIKit

@MainActor struct HandwritingRecognitionTests {
    // Fixtures are immutable after capture: their package is removed before recognition.
    private func snapshot(region: Rect = Rect(x: -20_000, y: 30_000, width: 700, height: 160),
                          image: Data? = nil, drawing: Data? = nil, missing: Bool = false) async throws -> KnowledgeSourceSnapshot {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultStore(root: root); try await store.prepare()
        var content = DocumentContent(kind: .infinity)
        var assets: [String: Data] = [:]
        if let image {
            content.pages[0].objects = [.init(kind: .image, frame: region, content: "assets/printed.png")]
            assets["assets/printed.png"] = image
        }
        if let drawing {
            content.pages[0].shards = [.init(file: "assets/ink.drawing", bounds: region)]
            assets["assets/ink.drawing"] = drawing
        }
        if missing { content.pages[0].drawingFile = "assets/missing.drawing" }
        try await store.save("OCR.studycanvas", content: content, expectedRevision: nil, assets: assets)
        return try await store.knowledgeSnapshot("OCR.studycanvas", pageID: content.pages[0].id,
                                                 region: region, includeAssets: true)
    }

    @Test(arguments: [LocalRecognitionLanguage.japanese, .russian, .english])
    func printedLanguageRunsActualSelectedVisionRequest(_ language: LocalRecognitionLanguage) async throws {
        let phrase: String
        switch language {
        case .japanese: phrase = "日本語の勉強"
        case .russian: phrase = "Привет мир"
        case .english: phrase = "Hello world"
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 700, height: 160)).image { output in
            UIColor.white.setFill(); output.fill(CGRect(x: 0, y: 0, width: 700, height: 160))
            (phrase as NSString).draw(at: CGPoint(x: 25, y: 40), withAttributes: [
                .font: UIFont.systemFont(ofSize: 56), .foregroundColor: UIColor.black
            ])
        }
        let captured = try await snapshot(image: #require(image.pngData()))
        let output = try await LocalHandwritingRecognition.recognize(captured, language: language)
        #expect(output.state == .complete)
        #expect(output.requestedLanguage == language)
        #expect(output.recognitionLanguages == language.recognitionLanguages)
        #expect(output.sourceFingerprint == captured.sourceFingerprint)
        #expect(output.snapshotFingerprint == captured.fingerprint)
        #expect(!output.runFingerprint.isEmpty)
        let actual = output.observations.map(\.text).joined().replacingOccurrences(of: " ", with: "").lowercased()
        #expect(actual.contains(phrase.replacingOccurrences(of: " ", with: "").lowercased()))
        for observation in output.observations {
            #expect(observation.worldRect.x >= -20_000)
            #expect(observation.worldRect.y >= 30_000)
            #expect(observation.worldRect.x + observation.worldRect.width <= -19_300)
            #expect(observation.worldRect.y + observation.worldRect.height <= 30_160)
            #expect((0...1).contains(observation.confidence))
        }
    }

    @Test func lowerLeftCoordinatesMapAndClampAtFarNegativeOrigin() throws {
        let crop = Rect(x: -1_000_000, y: -2_000_000, width: 800, height: 400)
        let box = try LocalHandwritingRecognition.worldRect(normalized: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), crop: crop)
        #expect(box == Rect(x: -999_800, y: -1_999_900, width: 400, height: 100))
        let clipped = try LocalHandwritingRecognition.worldRect(normalized: CGRect(x: -0.5, y: 0, width: 1, height: 1), crop: crop)
        #expect(clipped == Rect(x: crop.x, y: crop.y, width: 400, height: 400))
        #expect(throws: LocalRecognitionError.invalidRegion) {
            try LocalHandwritingRecognition.worldRect(normalized: CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1), crop: crop)
        }
        #expect(throws: LocalRecognitionError.invalidRegion) {
            try LocalHandwritingRecognition.worldRect(normalized: .zero, crop: Rect(width: 8193, height: 1))
        }
    }

    @Test func missingAndCorruptAssetsAreErrorsRatherThanEmptyRecognition() async throws {
        let missing = try await snapshot(missing: true)
        #expect(throws: LocalRecognitionError.missingAssets(["assets/missing.drawing"])) {
            try LocalHandwritingRecognition.render(missing)
        }
        let corrupt = try await snapshot(image: Data("not an image".utf8))
        #expect(throws: LocalRecognitionError.invalidAsset("assets/printed.png")) {
            try LocalHandwritingRecognition.render(corrupt)
        }
    }

    @Test func blankRequestIsEmptyAndCancellationCannotReturnAnOutput() async throws {
        let blank = try await snapshot()
        let output = try await LocalHandwritingRecognition.recognize(blank, language: .english)
        #expect(output.state == .empty)
        #expect(output.observations.isEmpty)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalHandwritingRecognition.recognize(blank, language: .english)
        }
        do { _ = try await task.value; Issue.record("Cancelled OCR returned an output") }
        catch is CancellationError {} // Caller can never commit a cancelled result.
    }

    @Test func rasterBoundsAndCapturedInkSurviveFarWorldCoordinates() async throws {
        let crop = Rect(x: -40_000, y: 90_000, width: 4000, height: 4000)
        let points = [CGPoint(x: crop.x + 100, y: crop.y + 200), CGPoint(x: crop.x + 3900, y: crop.y + 200)]
            .enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 40, height: 40),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
        let ink = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        let captured = try await snapshot(region: crop, drawing: ink.dataRepresentation())
        let raster = try LocalHandwritingRecognition.render(captured)
        #expect(raster.pixelWidth <= 2048 && raster.pixelHeight <= 2048)
        #expect(raster.pixelWidth * raster.pixelHeight <= 4_000_000)
        let image = try #require(UIImage(data: raster.pngData)?.cgImage)
        // Re-render to a known RGBA format, then verify the world-translated line is dark.
        var bytes = [UInt8](repeating: 255, count: 4)
        let sample = try #require(image.cropping(to: CGRect(x: raster.pixelWidth / 2, y: raster.pixelHeight / 20, width: 1, height: 1)))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(bytes[0] < 128 && bytes[1] < 128 && bytes[2] < 128)
    }
}
#endif
