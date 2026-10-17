#if canImport(UIKit)
import StudyCore
import UIKit

public extension CanvasRenderer {
    /// Immutable, byte-budgeted snapshot only. White paper is intentional; no asset hydration or OCR.
    static func knowledgeImage(_ snapshot: KnowledgeSourceSnapshot) throws -> UIImage {
        let raster = try LocalHandwritingRecognition.render(snapshot, includeTextObjects: true)
        guard let image = UIImage(data: raster.pngData) else { throw LocalRecognitionError.renderFailed }
        return image
    }
}
#endif
