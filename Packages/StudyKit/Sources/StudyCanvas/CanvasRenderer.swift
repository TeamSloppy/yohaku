#if canImport(UIKit)
import PencilKit
import StudyCore
import UIKit

public extension Rect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(_ rect: CGRect) { self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
}

public extension UIColor {
    convenience init(hex: String) {
        let number = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xFFFEFA
        self.init(red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
    }
}

@MainActor
public enum CanvasRenderer {
    public static func paper(_ paper: Paper, in rect: CGRect, context: CGContext) {
        UIColor(hex: paper.background).setFill(); context.fill(rect)
        guard paper.pattern != .plain else { return }
        let step = max(8, min(120, paper.spacing)), color = UIColor(hex: paper.lineColor)
        context.setStrokeColor(color.cgColor); context.setFillColor(color.cgColor); context.setLineWidth(0.5)
        let startX = floor(rect.minX / step) * step, startY = floor(rect.minY / step) * step
        if paper.pattern == .dots {
            for x in stride(from: startX, through: rect.maxX, by: step) {
                for y in stride(from: startY, through: rect.maxY, by: step) { context.fillEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)) }
            }
            return
        }
        for y in stride(from: startY, through: rect.maxY, by: step) { context.move(to: CGPoint(x: rect.minX, y: y)); context.addLine(to: CGPoint(x: rect.maxX, y: y)) }
        if paper.pattern != .lines {
            for x in stride(from: startX, through: rect.maxX, by: step) { context.move(to: CGPoint(x: x, y: rect.minY)); context.addLine(to: CGPoint(x: x, y: rect.maxY)) }
        }
        context.strokePath()
        if paper.pattern == .japanese {
            context.setLineDash(phase: 0, lengths: [2, 3]); context.setAlpha(0.5)
            for y in stride(from: startY + step / 2, through: rect.maxY, by: step) { context.move(to: CGPoint(x: rect.minX, y: y)); context.addLine(to: CGPoint(x: rect.maxX, y: y)) }
            for x in stride(from: startX + step / 2, through: rect.maxX, by: step) { context.move(to: CGPoint(x: x, y: rect.minY)); context.addLine(to: CGPoint(x: x, y: rect.maxY)) }
            context.strokePath(); context.setLineDash(phase: 0, lengths: []); context.setAlpha(1)
        }
    }

    public static func objects(_ objects: [CanvasObject], images: [String: UIImage], context: CGContext) {
        for object in objects {
            context.saveGState(); context.clip(to: object.frame.cgRect)
            switch object.kind {
            case .image: images[object.content]?.draw(in: object.frame.cgRect)
            case .text, .link:
                let frame = object.frame.cgRect
                UIColor(hex: object.kind == .link ? "E4ECE9" : "F5F0DC").setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: 10).fill()
                (object.content as NSString).draw(in: frame.insetBy(dx: 14, dy: 12), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor(hex: "24473F")
                ])
            }
            context.restoreGState()
        }
    }

    public static func image(session: DocumentSession, pageID: UUID, region: CGRect? = nil, scale: CGFloat = 2) async throws -> UIImage {
        guard let page = session.content.pages.first(where: { $0.id == pageID }) else { throw StudyError.missingPage }
        let rect = region ?? CGRect(x: 0, y: 0, width: page.width, height: page.height)
        guard rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite else { throw StudyError.invalidPath }
        var drawings: [PKDrawing] = []
        if let file = page.drawingFile { drawings.append(try PKDrawing(data: await session.asset(file))) }
        for shard in page.shards where shard.bounds.intersects(Rect(rect)) { drawings.append(try PKDrawing(data: await session.asset(shard.file))) }
        var images: [String: UIImage] = [:]
        for object in page.objects where object.kind == .image && object.frame.intersects(Rect(rect)) {
            images[object.content] = UIImage(data: try await session.asset(object.content))
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = min(scale, 2048 / max(rect.width, rect.height)); format.opaque = true
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = UIGraphicsImageRenderer(size: rect.size, format: format).image { renderer in
                let ctx = renderer.cgContext; ctx.translateBy(x: -rect.minX, y: -rect.minY)
                paper(page.paper, in: rect, context: ctx); objects(page.objects, images: images, context: ctx)
                for drawing in drawings { drawing.image(from: rect, scale: format.scale).draw(in: rect) }
            }
        }
        guard let image else { throw StudyError.invalidPath }
        return image
    }
}
#endif
