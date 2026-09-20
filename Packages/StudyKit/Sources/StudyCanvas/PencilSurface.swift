#if canImport(UIKit)
import PencilKit
import StudyCore
import SwiftUI
import UIKit

public struct CanvasPosition: Codable, Equatable, Sendable {
    public var x: Double = 0, y: Double = 0, zoom: Double = 0
    public init() {}
}

@MainActor
public final class CanvasHandle {
    public weak var surface: PencilSurfaceView?
    public init() {}
    public func undo() { surface?.undoDocument() }
    public func redo() { surface?.redoDocument() }
    public func home() { surface?.goHome() }
    public func removeSelected() { surface?.removeSelected() }
    public func resizeSelected(by factor: CGFloat) { surface?.resizeSelected(by: factor) }
}

public struct PencilSurface: UIViewRepresentable {
    public var session: DocumentSession
    public var pageID: UUID
    public var selecting: Bool
    public var movingObjects: Bool
    public var handle: CanvasHandle
    public var position: CanvasPosition
    public var onPosition: (CanvasPosition) -> Void
    public var onSelection: (SourceContext) -> Void
    public var onOpenLink: (String) -> Void
    public init(session: DocumentSession, pageID: UUID, selecting: Bool, movingObjects: Bool, handle: CanvasHandle,
                position: CanvasPosition = .init(), onPosition: @escaping (CanvasPosition) -> Void = { _ in },
                onSelection: @escaping (SourceContext) -> Void, onOpenLink: @escaping (String) -> Void) {
        self.session = session; self.pageID = pageID; self.selecting = selecting; self.movingObjects = movingObjects
        self.handle = handle; self.position = position; self.onPosition = onPosition; self.onSelection = onSelection; self.onOpenLink = onOpenLink
    }
    public func makeUIView(context: Context) -> PencilSurfaceView {
        let view = PencilSurfaceView(session: session, pageID: pageID, position: position)
        handle.surface = view; configure(view); return view
    }
    public func updateUIView(_ view: PencilSurfaceView, context: Context) { handle.surface = view; configure(view) }
    private func configure(_ view: PencilSurfaceView) {
        view.onPosition = onPosition; view.onSelection = onSelection; view.onOpenLink = onOpenLink
        view.setMode(selecting: selecting, movingObjects: movingObjects)
        view.updateContent()
    }
    public static func dismantleUIView(_ uiView: PencilSurfaceView, coordinator: ()) { uiView.finish(); uiView.picker.setVisible(false, forFirstResponder: uiView.canvas) }
}

@MainActor
public final class PencilSurfaceView: UIView, PKCanvasViewDelegate, PKToolPickerObserver {
    public let canvas = PKCanvasView()
    let picker: PKToolPicker
    private let decoration = CanvasDecoration()
    private let interaction = CanvasInteraction()
    private let session: DocumentSession
    private let pageID: UUID
    private var origin = CGPoint.zero
    private var loadedShardIDs: Set<UUID> = []
    private var loading = false
    private var drawing = false
    private var applying = false
    private var appliedFiles: [String] = []
    private var selectedObject: UUID?
    private var startObjectFrame: Rect?
    private var imageTask: Task<Void, Never>?
    private var drawingCommitTask: Task<Void, Never>?
    private var initialPosition: CanvasPosition?
    private var committedInk = PKDrawing().dataRepresentation()
    private var toolPickerBottomInset: CGFloat = 0
    private var isInfinity: Bool { session.content.kind == .infinity }
    public var onPosition: (CanvasPosition) -> Void = { _ in }
    public var onSelection: (SourceContext) -> Void = { _ in }
    public var onOpenLink: (String) -> Void = { _ in }

    public init(session: DocumentSession, pageID: UUID, position: CanvasPosition = .init()) {
        self.session = session; self.pageID = pageID; self.initialPosition = position
        self.picker = Self.makeToolPicker()
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        canvas.delegate = self
        #if targetEnvironment(macCatalyst)
        // A Mac has no Apple Pencil. Let the mouse or trackpad draw while the
        // scroll view continues to provide native pan and zoom gestures.
        canvas.drawingPolicy = .anyInput
        #else
        canvas.drawingPolicy = .pencilOnly
        #endif
        canvas.isOpaque = false; canvas.backgroundColor = .clear
        canvas.minimumZoomScale = 0.25; canvas.maximumZoomScale = 4
        canvas.alwaysBounceVertical = true; canvas.alwaysBounceHorizontal = true
        canvas.accessibilityIdentifier = "pencil-canvas"
        addSubview(decoration); addSubview(canvas); decoration.isUserInteractionEnabled = false
        decoration.isOpaque = false; decoration.backgroundColor = .clear
        addSubview(interaction)
        interaction.onDrag = { [weak self] phase, start, end in self?.interact(phase: phase, start: start, end: end) }
        interaction.onTap = { [weak self] point in self?.selectObject(at: point) }
        picker.addObserver(canvas)
        picker.addObserver(self)
        if isInfinity { origin = CGPoint(x: position.x - 4096, y: position.y - 4096) }
        updateContent()
    }
    required init?(coder: NSCoder) { nil }
    private static func makeToolPicker() -> PKToolPicker {
        let items: [PKToolPickerItem] = PKToolPicker.defaultToolItems.map { item in
            if item is PKToolPickerEraserItem { return PKToolPickerEraserItem(type: .bitmap) as PKToolPickerItem }
            return item
        }
        return PKToolPicker(toolItems: items)
    }
    public override func layoutSubviews() {
        super.layoutSubviews(); decoration.frame = bounds; canvas.frame = bounds; interaction.frame = bounds
        if let page = page {
            canvas.contentSize = isInfinity ? CGSize(width: 8192, height: 8192) : CGSize(width: page.width, height: page.height)
            if let initialPosition, !bounds.isEmpty {
                canvas.zoomScale = initialPosition.zoom > 0 ? initialPosition.zoom : (isInfinity ? 1 : min(1.5, bounds.width / page.width))
                canvas.contentOffset = CGPoint(x: (initialPosition.x - origin.x) * canvas.zoomScale, y: (initialPosition.y - origin.y) * canvas.zoomScale)
                self.initialPosition = nil
            }
        }
        updateDecoration()
        updateToolPickerInset()
    }
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && !interaction.isUserInteractionEnabled { picker.setVisible(true, forFirstResponder: canvas); canvas.becomeFirstResponder() }
        updateToolPickerInset()
    }
    private var page: CanvasPage? { session.content.pages.first { $0.id == pageID } }
    public func setMode(selecting: Bool, movingObjects: Bool) {
        interaction.isUserInteractionEnabled = selecting || movingObjects
        interaction.moving = movingObjects
        canvas.isUserInteractionEnabled = !selecting && !movingObjects
        if window != nil {
            picker.setVisible(!selecting && !movingObjects, forFirstResponder: canvas)
            if !selecting && !movingObjects && !canvas.isFirstResponder { canvas.becomeFirstResponder() }
        }
        updateToolPickerInset()
        if !movingObjects { selectedObject = nil; interaction.selection = nil }
    }
    public func updateContent() {
        guard let page else { return }
        decoration.page = page
        let wanted = Set(page.objects.filter { $0.kind == .image && $0.frame.intersects(Rect(visibleWorld.insetBy(dx: -512, dy: -512))) }.map(\.content))
        decoration.images = decoration.images.filter { wanted.contains($0.key) }
        let missing = wanted.subtracting(decoration.images.keys)
        if !missing.isEmpty {
            imageTask?.cancel()
            imageTask = Task { [weak self] in
                guard let self else { return }
                for name in missing {
                    do { let data = try await session.asset(name); try Task.checkCancellation(); decoration.images[name] = UIImage(data: data) }
                    catch is CancellationError { return } catch { session.error = error.localizedDescription }
                }
                updateDecoration()
            }
        }
        let files = isInfinity ? page.shards.filter { loadedShardIDs.contains($0.id) }.map(\.file) : [page.drawingFile].compactMap { $0 }
        if files != appliedFiles || (isInfinity && loadedShardIDs.isEmpty) { Task { await reloadInk() } }
        updateDecoration()
    }
    private var visibleWorld: CGRect {
        CGRect(x: canvas.contentOffset.x / canvas.zoomScale + origin.x, y: canvas.contentOffset.y / canvas.zoomScale + origin.y,
               width: bounds.width / canvas.zoomScale, height: max(0, bounds.height - toolPickerBottomInset) / canvas.zoomScale)
    }
    private func world(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x + canvas.contentOffset.x) / canvas.zoomScale + origin.x,
                y: (point.y + canvas.contentOffset.y) / canvas.zoomScale + origin.y)
    }
    private func screen(_ rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX - origin.x) * canvas.zoomScale - canvas.contentOffset.x,
               y: (rect.minY - origin.y) * canvas.zoomScale - canvas.contentOffset.y,
               width: rect.width * canvas.zoomScale, height: rect.height * canvas.zoomScale)
    }
    private func updateDecoration() {
        decoration.visible = visibleWorld; decoration.zoom = canvas.zoomScale
        decoration.infinite = isInfinity; decoration.setNeedsDisplay()
        if let selectedObject, let object = page?.objects.first(where: { $0.id == selectedObject }) { interaction.selection = screen(object.frame.cgRect) }
    }
    private func reloadInk(recenter: Bool = false) async {
        guard !loading, !drawing, let page else { return }
        loading = true; canvas.isUserInteractionEnabled = false
        defer { loading = false; canvas.isUserInteractionEnabled = !interaction.isUserInteractionEnabled }
        let visible = visibleWorld, expanded = visible.insetBy(dx: -1024, dy: -1024)
        let shards = page.shards.filter { $0.bounds.intersects(Rect(expanded)) }
        let files = isInfinity ? shards.map(\.file) : [page.drawingFile].compactMap { $0 }
        do {
            var strokes: [PKStroke] = []
            for file in files { strokes += try PKDrawing(data: await session.asset(file)).strokes }
            if recenter && isInfinity {
                origin = CGPoint(x: visible.minX - 4096, y: visible.minY - 4096)
                canvas.contentOffset = CGPoint(x: 4096 * canvas.zoomScale, y: 4096 * canvas.zoomScale)
            }
            applying = true
            canvas.drawing = PKDrawing(strokes: strokes).transformed(using: CGAffineTransform(translationX: -origin.x, y: -origin.y))
            committedInk = PKDrawing(strokes: strokes).dataRepresentation()
            canvas.undoManager?.removeAllActions()
            appliedFiles = files; loadedShardIDs = Set(shards.map(\.id))
            applying = false; updateDecoration()
        } catch { session.error = "Не удалось загрузить рукопись: \(error.localizedDescription)" }
    }
    public func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        drawingCommitTask?.cancel()
        drawingCommitTask = nil
        drawing = true
    }
    public func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        drawing = false
        scheduleDrawingCommit()
    }
    public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !applying, !loading, !drawing else { return }
        scheduleDrawingCommit()
    }
    private func scheduleDrawingCommit() {
        drawingCommitTask?.cancel()
        drawingCommitTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }
    public func finish() {
        drawingCommitTask?.cancel()
        drawingCommitTask = nil
        guard !applying, !loading, let pageIndex = session.content.pages.firstIndex(where: { $0.id == pageID }) else { return }
        let ink = canvas.drawing.transformed(using: CGAffineTransform(translationX: origin.x, y: origin.y))
        let data = ink.dataRepresentation()
        guard data != committedInk else { return }
        committedInk = data
        if isInfinity {
            // One owner per complete stroke; bounds index also loads strokes crossing tile boundaries.
            let grouped = Dictionary(grouping: ink.strokes) { stroke in
                "\(Int(floor(stroke.renderBounds.midX / 1024))),\(Int(floor(stroke.renderBounds.midY / 1024)))"
            }
            var shards: [InkShard] = []
            for key in grouped.keys.sorted() {
                let drawing = PKDrawing(strokes: grouped[key] ?? [])
                let file = session.addAsset(drawing.dataRepresentation(), extension: "drawing")
                shards.append(.init(file: file, bounds: Rect(drawing.bounds)))
            }
            let oldIDs = loadedShardIDs
            loadedShardIDs = Set(shards.map(\.id)); appliedFiles = shards.map(\.file)
            session.edit { document in
                document.pages[pageIndex].shards.removeAll { oldIDs.contains($0.id) }
                document.pages[pageIndex].shards += shards
            }
        } else {
            let file = session.addAsset(data, extension: "drawing")
            appliedFiles = [file]
            session.edit { $0.pages[pageIndex].drawingFile = file }
        }
    }
    public func scrollViewDidScroll(_ scrollView: UIScrollView) { updateDecoration(); reportPosition() }
    public func scrollViewDidZoom(_ scrollView: UIScrollView) { updateDecoration(); reportPosition() }
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { navigationEnded() }
    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { navigationEnded() } }
    public func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { navigationEnded() }
    public func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) { updateToolPickerInset() }
    public func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) { updateToolPickerInset() }
    public func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        guard let eraser = toolPicker.selectedToolItem as? PKToolPickerEraserItem else { return }
        canvas.tool = PKEraserTool(.bitmap, width: eraser.eraserTool.width)
    }
    private func updateToolPickerInset() {
        guard window != nil else { return }
        let obscured = picker.frameObscured(in: self)
        let inset = obscured.isNull || obscured.isEmpty ? 0 : max(0, bounds.maxY - obscured.minY + 12)
        guard abs(inset - toolPickerBottomInset) > 0.5 else { return }
        toolPickerBottomInset = inset
        canvas.contentInset.bottom = inset
        canvas.verticalScrollIndicatorInsets.bottom = inset
        updateDecoration()
    }
    private func reportPosition() {
        guard initialPosition == nil else { return }
        var position = CanvasPosition(); position.x = visibleWorld.minX; position.y = visibleWorld.minY; position.zoom = canvas.zoomScale
        onPosition(position)
    }
    private func navigationEnded() {
        if isInfinity { Task { await reloadInk(recenter: true); updateContent() } }
        else { updateContent() }
    }
    public func goHome() {
        canvas.zoomScale = isInfinity ? 1 : min(1.5, bounds.width / (page?.width ?? 595))
        canvas.contentOffset = CGPoint(x: -origin.x, y: -origin.y)
        navigationEnded()
    }
    public func undoDocument() { session.undo(); updateContent() }
    public func redoDocument() { session.redo(); updateContent() }
    private func selectObject(at point: CGPoint) {
        let point = world(point)
        if let object = page?.objects.reversed().first(where: { $0.frame.cgRect.contains(point) }) {
            if selectedObject == object.id && object.kind == .link { onOpenLink(object.content) }
            selectedObject = object.id
        } else { selectedObject = nil; interaction.selection = nil }
        updateDecoration()
    }
    private func interact(phase: UIGestureRecognizer.State, start: CGPoint, end: CGPoint) {
        if interaction.moving {
            if phase == .began { selectObject(at: start); startObjectFrame = page?.objects.first(where: { $0.id == selectedObject })?.frame; session.beginEditingGroup() }
            defer { if phase == .ended || phase == .cancelled { session.endEditingGroup() } }
            guard let selectedObject, let initial = startObjectFrame,
                  let p = session.content.pages.firstIndex(where: { $0.id == pageID }),
                  let o = session.content.pages[p].objects.firstIndex(where: { $0.id == selectedObject }) else { return }
            session.edit { document in
                document.pages[p].objects[o].frame.x = initial.x + (end.x - start.x) / canvas.zoomScale
                document.pages[p].objects[o].frame.y = initial.y + (end.y - start.y) / canvas.zoomScale
            }
            updateContent(); return
        }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        interaction.selection = rect
        guard phase == .ended, rect.width >= 20, rect.height >= 20 else { return }
        let worldOrigin = world(rect.origin)
        var region = CGRect(origin: worldOrigin, size: CGSize(width: rect.width / canvas.zoomScale, height: rect.height / canvas.zoomScale))
        if !isInfinity, let page { region = region.intersection(CGRect(x: 0, y: 0, width: page.width, height: page.height)) }
        guard !region.isNull && !region.isEmpty else { return }
        Task {
            do {
                let image = try await CanvasRenderer.image(session: session, pageID: pageID, region: region)
                onSelection(SourceContext(path: session.path, pageID: pageID, region: Rect(region), image: image.pngData()))
            } catch { session.error = error.localizedDescription }
        }
    }
    public func removeSelected() {
        guard let selectedObject, let p = session.content.pages.firstIndex(where: { $0.id == pageID }) else { return }
        session.edit { $0.pages[p].objects.removeAll { $0.id == selectedObject } }
        self.selectedObject = nil; interaction.selection = nil; updateContent()
    }
    public func resizeSelected(by factor: CGFloat) {
        guard let selectedObject, let p = session.content.pages.firstIndex(where: { $0.id == pageID }), let o = session.content.pages[p].objects.firstIndex(where: { $0.id == selectedObject }) else { return }
        session.edit { document in
            document.pages[p].objects[o].frame.width = max(40, min(2000, document.pages[p].objects[o].frame.width * factor))
            document.pages[p].objects[o].frame.height = max(40, min(2000, document.pages[p].objects[o].frame.height * factor))
        }
        updateContent()
    }
}

@MainActor private final class CanvasDecoration: UIView {
    var page = CanvasPage()
    var images: [String: UIImage] = [:]
    var visible = CGRect.zero
    var zoom: CGFloat = 1
    var infinite = false
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.scaleBy(x: zoom, y: zoom); context.translateBy(x: -visible.minX, y: -visible.minY)
        if !infinite { context.clip(to: CGRect(x: 0, y: 0, width: page.width, height: page.height)) }
        CanvasRenderer.paper(page.paper, in: visible, context: context)
        CanvasRenderer.objects(page.objects.filter { $0.frame.intersects(Rect(visible)) }, images: images, context: context)
    }
}

@MainActor private final class CanvasInteraction: UIView {
    var selection: CGRect? { didSet { setNeedsDisplay() } }
    var moving = false
    var onDrag: (UIGestureRecognizer.State, CGPoint, CGPoint) -> Void = { _, _, _ in }
    var onTap: (CGPoint) -> Void = { _ in }
    private var start = CGPoint.zero
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear; isOpaque = false
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan)))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
    }
    required init?(coder: NSCoder) { nil }
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { start = gesture.location(in: self) }
        onDrag(gesture.state, start, gesture.location(in: self))
    }
    @objc private func tap(_ gesture: UITapGestureRecognizer) { onTap(gesture.location(in: self)) }
    override func draw(_ rect: CGRect) {
        guard let selection else { return }
        let path = UIBezierPath(roundedRect: selection, cornerRadius: 6)
        UIColor.systemTeal.withAlphaComponent(0.12).setFill(); path.fill()
        UIColor.systemTeal.setStroke(); path.lineWidth = 2; path.setLineDash([6, 4], count: 2, phase: 0); path.stroke()
    }
}
#endif
