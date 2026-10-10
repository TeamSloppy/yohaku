import SwiftUI
import UIKit

struct KanaTracingView: View {
    let alphabet: KanaAlphabet
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: [KanaGlyph] = []
    @State private var row = 0
    @State private var session = KanaTracingSession(glyphs: [])
    @State private var loadError = false
    @State private var resetID = UUID()

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 16) {
                        if loadError {
                            ContentUnavailableView("Не удалось загрузить прописи", systemImage: "exclamationmark.triangle",
                                                   description: Text("Попробуйте открыть задание снова."))
                        } else if let glyph = session.current {
                            lessonHeader
                            Text("Обведите подсвеченный штрих от точки по стрелке")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            let side = min(460, geometry.size.width - 40, max(140, geometry.size.height - 280))
                            KanaTracingBoard(glyph: glyph, accepted: session.acceptedStrokes,
                                             rejected: session.rejectedStroke, resetID: resetID) { points in
                                session.submit(points)
                            }
                            .frame(width: side, height: side)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.secondary.opacity(0.18)))
                            Text(glyph.reading)
                                .font(.largeTitle.weight(.medium))
                                .accessibilityLabel("Звучание: \(glyph.reading)")
                                .accessibilityIdentifier("kana-reading")
                            feedback
                            HStack(spacing: 16) {
                                Button("Заново", systemImage: "arrow.counterclockwise") {
                                    session.resetCharacter()
                                    resetID = UUID()
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("kana-reset")
                                Button(session.index == session.glyphs.count - 1 ? "Завершить" : "Следующий знак",
                                       systemImage: "arrow.right") {
                                    session.advance()
                                    resetID = UUID()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!session.characterComplete)
                                .accessibilityIdentifier("kana-next")
                            }
                        } else if !catalog.isEmpty {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(Palette.accent)
                            Text("Ряд завершён").font(.title.bold()).accessibilityIdentifier("kana-complete")
                            Text("Вы обвели \(session.glyphs.count) знаков \(alphabet == .hiragana ? "хираганы" : "катаканы").")
                            Button("Повторить ряд") { startRow() }.buttonStyle(.bordered)
                            if row < 9 {
                                Button("Следующий ряд") { row += 1 }.buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("kana-next-row")
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(Palette.background)
            .navigationTitle("Пропись · \(alphabet.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("close-kana-tracing")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Ряд", selection: $row) {
                            ForEach(0..<10) { index in
                                Text(catalog.filter { $0.alphabet == alphabet && $0.row == index }
                                    .map(\.symbol).joined(separator: " ")).tag(index)
                            }
                        }
                        Divider()
                        Link("Штрихи: KanjiVG · Ulrich Apel", destination: URL(string: "https://kanjivg.tagaini.net/")!)
                        Link("Лицензия CC BY-SA 3.0", destination: URL(string: "https://creativecommons.org/licenses/by-sa/3.0/")!)
                    } label: { Label("Выбрать ряд", systemImage: "square.grid.3x3") }
                    .accessibilityIdentifier("kana-choose-row")
                    .disabled(catalog.isEmpty)
                }
            }
            .task {
                do { catalog = try KanaCatalog.load(); startRow() }
                catch { loadError = true }
            }
            .onChange(of: row) { _, _ in startRow() }
        }
        .tint(Palette.accent)
    }

    private var lessonHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Знак \(session.index + 1) из \(session.glyphs.count)").font(.headline)
                Spacer()
                if let glyph = session.current {
                    Text("Штрихи: \(session.acceptedStrokes.count)/\(glyph.strokes.count)")
                        .font(.subheadline.monospacedDigit())
                        .accessibilityIdentifier("kana-stroke-count")
                }
            }
            ProgressView(value: Double(session.completedCount), total: Double(max(1, session.glyphs.count)))
        }
        .frame(maxWidth: 460)
    }

    private var feedback: some View {
        Text(session.characterComplete ? "Верно! Знак обведён." :
                session.feedback?.message ?? "Пишите пальцем или Apple Pencil")
            .font(.subheadline)
            .foregroundStyle(session.feedback == nil ? Color.secondary :
                                session.feedback == .accepted ? Palette.accent : Color.orange)
            .multilineTextAlignment(.center)
            .frame(minHeight: 40)
            .accessibilityIdentifier("kana-feedback")
    }

    private func startRow() {
        session = KanaTracingSession(glyphs: catalog.filter { $0.alphabet == alphabet && $0.row == row })
        resetID = UUID()
    }
}

private struct KanaTracingBoard: UIViewRepresentable {
    let glyph: KanaGlyph
    let accepted: [[KanaPoint]]
    let rejected: [KanaPoint]
    let resetID: UUID
    var onStroke: ([KanaPoint]) -> Void

    func makeUIView(context: Context) -> KanaInkView { KanaInkView() }
    func updateUIView(_ view: KanaInkView, context: Context) {
        if view.glyph?.id != glyph.id || view.resetID != resetID {
            view.cancelStroke()
        }
        view.glyph = glyph
        view.accepted = accepted
        view.rejected = rejected
        view.resetID = resetID
        view.onStroke = onStroke
        view.accessibilityLabel = "Обведите \(glyph.symbol), звучание \(glyph.reading)"
        view.accessibilityValue = "Штрихи: \(accepted.count)/\(glyph.strokes.count)"
        view.setNeedsDisplay()
    }
}

/// A single uninterrupted touch is a stroke; coalesced Pencil/finger samples keep
/// curves accurate. Separate from note editing so scrolling/tool palettes never
/// consume handwriting or cover the reading below the tracing board.
private final class KanaInkView: UIView {
    var glyph: KanaGlyph?
    var accepted: [[KanaPoint]] = []
    var rejected: [KanaPoint] = []
    var resetID: UUID?
    var onStroke: (([KanaPoint]) -> Void)?
    private var activeTouch: UITouch?
    private var ink: [KanaPoint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityIdentifier = "kana-tracing-board"
        accessibilityTraits = [.allowsDirectInteraction]
        // Claim touches immediately inside the board, before the surrounding
        // ScrollView can turn a vertical pen stroke into a scroll gesture.
        let drawingGesture = KanaDrawingGesture()
        drawingGesture.cancelsTouchesInView = false
        drawingGesture.delaysTouchesBegan = false
        drawingGesture.delaysTouchesEnded = false
        addGestureRecognizer(drawingGesture)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func cancelStroke() {
        activeTouch = nil
        ink = []
        setNeedsDisplay()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let glyph, accepted.count < glyph.strokes.count,
              let touch = touches.first(where: { $0.type == .pencil }) ?? touches.first else { return }
        activeTouch = touch
        rejected = []
        ink = [normalized(touch.location(in: self))]
        setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            let point = normalized(sample.location(in: self))
            if ink.last.map({ $0.distance(to: point) > 0.001 }) ?? true { ink.append(point) }
        }
        setNeedsDisplay()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        ink.append(normalized(touch.location(in: self)))
        let points = ink
        cancelStroke()
        onStroke?(points)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelStroke() }

    private var side: CGFloat { min(bounds.width, bounds.height) }
    private var origin: CGPoint { CGPoint(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2) }
    private func normalized(_ point: CGPoint) -> KanaPoint {
        KanaPoint(x: Double((point.x - origin.x) / max(1, side)), y: Double((point.y - origin.y) / max(1, side)))
    }
    private func scaled(_ point: KanaPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * side, y: origin.y + point.y * side)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let glyph else { return }
        UIColor(Palette.surface).setFill()
        context.fill(bounds)
        let grid = UIBezierPath()
        grid.move(to: CGPoint(x: bounds.midX, y: origin.y))
        grid.addLine(to: CGPoint(x: bounds.midX, y: origin.y + side))
        grid.move(to: CGPoint(x: origin.x, y: bounds.midY))
        grid.addLine(to: CGPoint(x: origin.x + side, y: bounds.midY))
        grid.setLineDash([5, 5], count: 2, phase: 0)
        UIColor.separator.withAlphaComponent(0.5).setStroke()
        grid.stroke()
        let accent = UIColor(Palette.accent)
        for stroke in glyph.strokes { draw(stroke, color: .label.withAlphaComponent(0.10), width: side * 0.032) }
        if accepted.count < glyph.strokes.count {
            let expected = glyph.strokes[accepted.count]
            draw(expected, color: accent.withAlphaComponent(0.25), width: side * 0.034)
            if let start = expected.first {
                let location = scaled(start)
                accent.setFill()
                UIBezierPath(ovalIn: CGRect(x: location.x - 6, y: location.y - 6, width: 12, height: 12)).fill()
                let label = "\(accepted.count + 1)" as NSString
                label.draw(at: CGPoint(x: location.x - 20, y: location.y - 24), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: accent
                ])
                // A short arrow follows the actual curve tangent after its start.
                let samples = KanaStrokeMatcher.resample(expected, count: 12)
                let a = scaled(samples[1]), b = scaled(samples[2])
                let angle = atan2(b.y - a.y, b.x - a.x)
                let arrow = UIBezierPath()
                arrow.move(to: CGPoint(x: b.x - 9 * cos(angle - .pi / 6), y: b.y - 9 * sin(angle - .pi / 6)))
                arrow.addLine(to: b)
                arrow.addLine(to: CGPoint(x: b.x - 9 * cos(angle + .pi / 6), y: b.y - 9 * sin(angle + .pi / 6)))
                arrow.lineWidth = 2
                accent.setStroke()
                arrow.stroke()
            }
        }
        for stroke in accepted { draw(stroke, color: accent, width: side * 0.018) }
        draw(rejected, color: .systemOrange.withAlphaComponent(0.75), width: side * 0.018)
        draw(ink, color: .label, width: side * 0.018)
    }

    private func draw(_ points: [KanaPoint], color: UIColor, width: CGFloat) {
        guard let first = points.first else { return }
        let path = UIBezierPath()
        path.move(to: scaled(first))
        for point in points.dropFirst() { path.addLine(to: scaled(point)) }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}

private final class KanaDrawingGesture: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible { state = .began }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { state = .changed }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if event.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) ?? true { state = .ended }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
}
