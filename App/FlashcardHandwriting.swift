import Observation
import PencilKit
import StudyCanvas
import StudyCore
import SwiftUI

/// Keep the existing drawing coordinates, including ink from older cards.
private let handwritingSize = CGSize(width: 600, height: 240)

/// One native palette follows the active field and preserves the selected tool.
@MainActor @Observable final class FlashcardDrawingTools: NSObject, PKToolPickerObserver {
    private(set) var activeIdentifier: String?
    private(set) var bottomInset: CGFloat = 0
    @ObservationIgnored private let picker = PKToolPicker()
    @ObservationIgnored private var canvases: [String: WeakCanvas] = [:]
    @ObservationIgnored private weak var activeCanvas: PKCanvasView?

    private struct WeakCanvas { weak var value: PKCanvasView? }

    override init() {
        super.init()
        picker.colorUserInterfaceStyle = .light
        picker.addObserver(self)
    }

    func register(_ canvas: PKCanvasView, identifier: String) {
        canvases[identifier] = WeakCanvas(value: canvas)
        picker.addObserver(canvas)
        // PKCanvasView applies native inking, eraser, lasso, and drawingEnabled state.
        let observer: any PKToolPickerObserver = canvas
        observer.toolPickerSelectedToolItemDidChange?(picker)
    }

    func unregister(_ canvas: PKCanvasView, identifier: String) {
        if activeCanvas === canvas { hide() }
        picker.setVisible(false, forFirstResponder: canvas)
        picker.removeObserver(canvas)
        canvases.removeValue(forKey: identifier)
    }

    func toggle(for identifier: String) {
        if activeIdentifier == identifier, picker.isVisible { hide(); return }
        guard let canvas = canvases[identifier]?.value else { return }
        activate(canvas, identifier: identifier)
    }

    func follow(_ canvas: PKCanvasView, identifier: String) {
        guard activeIdentifier != nil, activeCanvas !== canvas else { return }
        activate(canvas, identifier: identifier)
    }

    private func activate(_ canvas: PKCanvasView, identifier: String) {
        guard canvas.window != nil else { return }
        if let previous = activeCanvas, previous !== canvas {
            picker.setVisible(false, forFirstResponder: previous)
        }
        activeCanvas = canvas
        activeIdentifier = identifier
        picker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
        updateInset()
    }

    func hide() {
        if let canvas = activeCanvas {
            picker.setVisible(false, forFirstResponder: canvas)
            canvas.resignFirstResponder()
        }
        activeCanvas = nil
        activeIdentifier = nil
        bottomInset = 0
    }

    func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) { updateInset() }
    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) { updateInset() }

    private func updateInset() {
        guard picker.isVisible, let window = activeCanvas?.window else { bottomInset = 0; return }
        let frame = picker.frameObscured(in: window)
        // Floating iPad palettes do not reserve the entire bottom of the form.
        guard !frame.isNull, frame.maxY >= window.bounds.maxY - window.safeAreaInsets.bottom - 1 else {
            bottomInset = 0
            return
        }
        bottomInset = max(0, window.bounds.maxY - frame.minY - window.safeAreaInsets.bottom)
    }
}

struct FlashcardHandwritingField: View {
    let title: String
    let identifier: String
    @Binding var drawing: Data?
    let tools: FlashcardDrawingTools
    var pattern: PaperPattern = .japanese

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button { tools.toggle(for: identifier) } label: {
                    Image(systemName: "pencil.tip.crop.circle")
                        .foregroundStyle(tools.activeIdentifier == identifier ? Palette.accent : .secondary)
                }
                .accessibilityLabel("Инструменты: \(title)")
                .accessibilityIdentifier("\(identifier)-tools")
                Button { drawing = nil } label: { Image(systemName: "trash") }
                    .disabled(drawing == nil)
                    .accessibilityLabel("Очистить: \(title)")
                    .accessibilityIdentifier("\(identifier)-clear")
            }
            .buttonStyle(.borderless)

            HandwritingCanvas(drawing: $drawing, tools: tools, identifier: identifier, title: title)
                .aspectRatio(handwritingSize.width / handwritingSize.height, contentMode: .fit)
                .background { HandwritingPaper(pattern: pattern).allowsHitTesting(false) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.gray.opacity(0.2)) }
        }
        .padding(.vertical, 6)
    }
}

private struct HandwritingPaper: UIViewRepresentable {
    let pattern: PaperPattern
    func makeUIView(context: Context) -> HandwritingPaperView { HandwritingPaperView() }
    func updateUIView(_ view: HandwritingPaperView, context: Context) { view.pattern = pattern }
}

private final class HandwritingPaperView: UIView {
    var pattern: PaperPattern = .japanese { didSet { if pattern != oldValue { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        contentMode = .redraw
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !bounds.isEmpty else { return }
        var paper = Paper()
        paper.pattern = pattern
        paper.spacing = 120 // Five square cells across, two rows, in drawing coordinates.
        paper.background = "FFFFFF"
        paper.lineColor = "7A9689"
        context.saveGState()
        let scale = min(bounds.width / handwritingSize.width, bounds.height / handwritingSize.height)
        context.scaleBy(x: scale, y: scale)
        CanvasRenderer.paper(paper, in: CGRect(origin: .zero, size: handwritingSize), context: context)
        context.restoreGState()
    }
}

private struct HandwritingCanvas: UIViewRepresentable {
    @Binding var drawing: Data?
    let tools: FlashcardDrawingTools
    let identifier: String
    let title: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> FixedHandwritingCanvas {
        let canvas = FixedHandwritingCanvas()
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = .anyInput
        canvas.overrideUserInterfaceStyle = .light
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.bounces = false
        canvas.accessibilityIdentifier = identifier
        canvas.accessibilityLabel = title
        tools.register(canvas, identifier: identifier)
        configure(canvas, context: context)
        return canvas
    }

    func updateUIView(_ canvas: FixedHandwritingCanvas, context: Context) {
        context.coordinator.parent = self
        configure(canvas, context: context)
    }

    static func dismantleUIView(_ canvas: FixedHandwritingCanvas, coordinator: Coordinator) {
        coordinator.parent.tools.unregister(canvas, identifier: coordinator.parent.identifier)
        canvas.delegate = nil
    }

    private func configure(_ canvas: PKCanvasView, context: Context) {
        guard context.coordinator.lastData != drawing else { return }
        context.coordinator.lastData = drawing
        context.coordinator.updating = true
        canvas.drawing = drawing.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        context.coordinator.updating = false
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: HandwritingCanvas
        var lastData: Data?
        var updating = false

        init(_ parent: HandwritingCanvas) { self.parent = parent }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            parent.tools.follow(canvasView, identifier: parent.identifier)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !updating else { return }
            let data = canvasView.drawing.strokes.isEmpty ? nil : canvasView.drawing.dataRepresentation()
            guard data != lastData else { return }
            lastData = data
            parent.drawing = data
        }
    }
}

private final class FixedHandwritingCanvas: PKCanvasView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / handwritingSize.width, bounds.height / handwritingSize.height)
        minimumZoomScale = scale
        maximumZoomScale = scale
        if abs(zoomScale - scale) > 0.001 { zoomScale = scale }
        contentSize = CGSize(width: handwritingSize.width * scale, height: handwritingSize.height * scale)
        contentOffset = .zero
    }
}

struct FlashcardFieldContent: View {
    let text: String
    let drawing: Data?
    var maxHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 6) {
            if let drawing, let image = FlashcardInkRenderer.image(from: drawing) {
                Image(uiImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(text.isEmpty ? "Рукописная запись" : text)
            }
            if !text.isEmpty { Text(text) }
        }
    }
}

@MainActor enum FlashcardInkRenderer {
    static func image(from data: Data) -> UIImage? {
        guard let ink = try? PKDrawing(data: data), !ink.strokes.isEmpty else { return nil }
        // PencilKit adapts ink to the current appearance. Card paper stays white.
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = ink.image(from: ink.bounds.insetBy(dx: -12, dy: -12), scale: 2)
        }
        return image
    }
}
