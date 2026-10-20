import Foundation

enum KanaAlphabet: String, CaseIterable, Identifiable, Codable, Sendable {
    case hiragana, katakana
    var id: String { rawValue }
    var title: String { self == .hiragana ? "Хирагана" : "Катакана" }
    var example: String { self == .hiragana ? "あ" : "ア" }
}

struct KanaPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    func distance(to other: Self) -> Double { hypot(x - other.x, y - other.y) }
}

struct KanaGlyph: Codable, Identifiable, Equatable, Sendable {
    let alphabet: KanaAlphabet?
    let row: Int
    let symbol: String
    let reading: String
    let strokes: [[KanaPoint]]
    var id: String { symbol }
}

enum KanaCatalog {
    private struct Templates: Decodable { let glyphs: [KanaGlyph] }
    static func load(bundle: Bundle = .main) throws -> [KanaGlyph] {
        guard let url = bundle.url(forResource: "KanaTemplates", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let glyphs = try JSONDecoder().decode(Templates.self, from: Data(contentsOf: url)).glyphs
        guard glyphs.count == 92, Set(glyphs.map(\.symbol)).count == 92,
              glyphs.allSatisfy({ glyph in
                  !glyph.reading.isEmpty && (0..<10).contains(glyph.row) && !glyph.strokes.isEmpty &&
                  glyph.strokes.allSatisfy { stroke in
                      stroke.count >= 2 && stroke.allSatisfy { point in
                          point.x.isFinite && point.y.isFinite &&
                          (0...1).contains(point.x) && (0...1).contains(point.y)
                      }
                  }
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return glyphs
    }
}

enum KanaStrokeResult: Equatable {
    case accepted, start, direction, shape, tooShort
    var message: String {
        switch self {
        case .accepted: "Штрих верный"
        case .start: "Начните в отмеченной точке и соблюдайте порядок штрихов."
        case .direction: "Ведите штрих по стрелке, в правильном направлении."
        case .shape: "Следуйте подсвеченному штриху до конца. Попробуйте ещё раз."
        case .tooShort: "Обведите весь подсвеченный штрих одним движением."
        }
    }
}

enum KanaStrokeMatcher {
    /// Compare positions along arc length, rather than event timing or sample count.
    /// This checks bends/loops and direction as well as endpoints, so a straight
    /// shortcut or scribble with the same start/end does not count as a trace.
    static func evaluate(_ input: [KanaPoint], against expected: [KanaPoint]) -> KanaStrokeResult {
        guard input.count >= 2, expected.count >= 2 else { return .tooShort }
        guard input.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            return .shape
        }
        let expectedLength = length(expected)
        let actualLength = length(input)
        guard expectedLength > 0, actualLength >= expectedLength * 0.65 else { return .tooShort }
        guard actualLength <= expectedLength * 1.5 else { return .shape }
        let actual = resample(input, count: 48)
        let reference = resample(expected, count: 48)
        let forwardError = meanError(actual, reference)
        let reverseError = meanError(actual, Array(reference.reversed()))
        if reverseError < 0.06 && reverseError + 0.025 < forwardError { return .direction }
        guard input[0].distance(to: expected[0]) <= 0.095 else { return .start }
        guard input.last!.distance(to: expected.last!) <= 0.095 else { return .shape }
        let distances = zip(actual, reference).map { $0.distance(to: $1) }
        guard forwardError <= 0.065, distances.max() ?? 1 <= 0.14 else { return .shape }
        return .accepted
    }

    private static func meanError(_ lhs: [KanaPoint], _ rhs: [KanaPoint]) -> Double {
        zip(lhs, rhs).map { $0.distance(to: $1) }.reduce(0, +) / Double(lhs.count)
    }

    static func length(_ points: [KanaPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    static func resample(_ points: [KanaPoint], count: Int) -> [KanaPoint] {
        guard let first = points.first, count >= 2 else { return points }
        var cumulative = [0.0]
        for (a, b) in zip(points, points.dropFirst()) { cumulative.append(cumulative.last! + a.distance(to: b)) }
        guard let total = cumulative.last, total > 0 else { return Array(repeating: first, count: count) }
        var segment = 1
        return (0..<count).map { index in
            let distance = total * Double(index) / Double(count - 1)
            while segment < points.count - 1, cumulative[segment] < distance { segment += 1 }
            let span = cumulative[segment] - cumulative[segment - 1]
            let fraction = span > 0 ? (distance - cumulative[segment - 1]) / span : 0
            let a = points[segment - 1], b = points[segment]
            return KanaPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
        }
    }
}

struct KanaTracingSession {
    let glyphs: [KanaGlyph]
    private(set) var index = 0
    private(set) var acceptedStrokes: [[KanaPoint]] = []
    private(set) var rejectedStroke: [KanaPoint] = []
    private(set) var feedback: KanaStrokeResult?
    var current: KanaGlyph? { glyphs.indices.contains(index) ? glyphs[index] : nil }
    var characterComplete: Bool { current.map { acceptedStrokes.count == $0.strokes.count } ?? false }
    var isComplete: Bool { index >= glyphs.count }
    var completedCount: Int { index + (characterComplete ? 1 : 0) }

    mutating func submit(_ points: [KanaPoint]) {
        guard let current, !characterComplete else { return }
        let result = KanaStrokeMatcher.evaluate(points, against: current.strokes[acceptedStrokes.count])
        feedback = result
        if result == .accepted {
            acceptedStrokes.append(points)
            rejectedStroke = []
        } else { rejectedStroke = points }
    }

    mutating func resetCharacter() {
        acceptedStrokes = []
        rejectedStroke = []
        feedback = nil
    }

    mutating func advance() {
        guard characterComplete else { return }
        index += 1
        resetCharacter()
    }
}
