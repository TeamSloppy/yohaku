import Foundation
import Testing
@testable import Yohaku

struct KanaTracingTests {
    @Test func bundledCatalogContainsBothCompleteAlphabetsAndAcceptsEveryReference() throws {
        let glyphs = try KanaCatalog.load()
        for alphabet in KanaAlphabet.allCases {
            let kana = glyphs.filter { $0.alphabet == alphabet }
            #expect(kana.count == 46)
            #expect(Set(kana.map(\.row)) == Set(0..<10))
            #expect(kana.first?.reading == "a")
            #expect(kana.last?.reading == "n")
            for glyph in kana {
                for stroke in glyph.strokes {
                    #expect(KanaStrokeMatcher.evaluate(stroke, against: stroke) == .accepted)
                    // Event density and slight handwriting variation should not change the result.
                    let varied = KanaStrokeMatcher.resample(stroke, count: 73)
                        .map { KanaPoint(x: $0.x + 0.012, y: $0.y - 0.009) }
                    #expect(KanaStrokeMatcher.evaluate(varied, against: stroke) == .accepted)
                    #expect(KanaStrokeMatcher.evaluate(Array(stroke.reversed()), against: stroke) != .accepted)
                }
            }
        }
    }

    @Test func rejectsTapsShortcutsWrongDirectionAndScribbles() throws {
        let glyph = try #require(try KanaCatalog.load().first { $0.symbol == "あ" })
        let horizontal = glyph.strokes[0]
        let loop = glyph.strokes[2]
        #expect(KanaStrokeMatcher.evaluate([horizontal[0]], against: horizontal) == .tooShort)
        #expect(KanaStrokeMatcher.evaluate(Array(horizontal.prefix(3)), against: horizontal) == .tooShort)
        #expect(KanaStrokeMatcher.evaluate(Array(horizontal.reversed()), against: horizontal) == .direction)
        #expect(KanaStrokeMatcher.evaluate([loop.first!, loop.last!], against: loop) != .accepted)
        let offset = horizontal.map { KanaPoint(x: $0.x, y: $0.y + 0.22) }
        #expect(KanaStrokeMatcher.evaluate(offset, against: horizontal) == .start)
        let scribble = Array(repeating: [horizontal.first!, horizontal.last!], count: 10).flatMap { $0 }
        #expect(KanaStrokeMatcher.evaluate(scribble, against: horizontal) == .shape)
        #expect(KanaStrokeMatcher.evaluate([KanaPoint(x: .nan, y: 0), horizontal.last!], against: horizontal) == .shape)
    }

    @Test func sessionEnforcesOrderAndCompletionAndResetsBetweenCharacters() throws {
        let glyphs = try KanaCatalog.load().filter { $0.alphabet == .hiragana && $0.row == 0 }
        var session = KanaTracingSession(glyphs: glyphs)
        let first = glyphs[0]
        session.advance()
        #expect(session.index == 0)
        session.submit(first.strokes[1])
        #expect(session.acceptedStrokes.isEmpty)
        #expect(!session.rejectedStroke.isEmpty)
        for stroke in first.strokes { session.submit(stroke) }
        #expect(session.characterComplete)
        #expect(session.completedCount == 1)
        #expect(session.rejectedStroke.isEmpty)
        session.resetCharacter()
        #expect(!session.characterComplete)
        #expect(session.completedCount == 0)
        for glyph in glyphs {
            for stroke in glyph.strokes { session.submit(stroke) }
            #expect(session.characterComplete)
            session.advance()
            #expect(session.acceptedStrokes.isEmpty)
            #expect(session.feedback == nil)
        }
        #expect(session.isComplete)
        #expect(session.completedCount == 5)
        session.submit(first.strokes[0])
        session.advance()
        #expect(session.index == 5)
    }
}
