import Foundation
import Testing
@testable import Yohaku

struct CourseContentTests {
    @Test func catalogHasUniqueStableModulesAndOnlyPreviouslyIntroducedScript() throws {
        let modules = try CourseCatalog.load()
        #expect(modules.count >= 28)
        #expect(modules.first?.id == "hiragana.row.0")
        #expect(Set(modules.map(\.id)).count == modules.count)
        var symbols = Set<Character>()
        for module in modules {
            #expect(module.items.count <= 20)
            #expect(!module.explanation.isEmpty)
            symbols.formUnion(module.items.filter { $0.glyph != nil }.flatMap(\.japanese))
            for item in module.items where item.glyph == nil {
                #expect(item.japanese.allSatisfy { symbols.contains($0) }, "Unintroduced script in \(module.id): \(item.japanese)")
            }
            let steps = CourseCatalog.steps(module, checkpoint: true, progress: .init(), duration: .standard)
            try LearningSession(duration: .long, steps: steps, course: .init(moduleID: module.id, catalogVersion: 1, checkpoint: true)).validate()
        }
    }
    @Test func everyStrokeReferenceIsAcceptedAndReverseDirectionRejected() throws {
        for glyph in try CourseTemplates.load() {
            for stroke in glyph.strokes {
                #expect(KanaStrokeMatcher.evaluate(stroke, against: stroke) == .accepted, "\(glyph.symbol)")
                #expect(KanaStrokeMatcher.evaluate(Array(stroke.reversed()), against: stroke) != .accepted, "\(glyph.symbol)")
            }
        }
    }
    @Test func shortLessonNeverShowsAWordContainingAnUnintroducedSign() throws {
        let module = try #require(CourseCatalog.load().first)
        let steps = CourseCatalog.steps(module, checkpoint: false, progress: .init(), duration: .short)
        #expect(steps.count <= DailyLessonDuration.short.capacity)
        #expect(!steps.contains { $0.card.japanese == "いえ" })
    }
    @Test func katakanaFollowsHiraganaAndReadingAcceptsBothKanaScripts() throws {
        let modules = try CourseCatalog.load()
        let index = try #require(modules.firstIndex { $0.id == "katakana.row.0" })
        #expect(modules.prefix(index).allSatisfy { $0.stage == "Хирагана" })
        #expect(!CourseCatalog.unlocked("katakana.row.0", modules: modules, progress: .init()))
        #expect(CourseAnswer.matches("カメラ", expected: "かめら", reading: true))
        #expect(CourseAnswer.matches("si", expected: "shi", reading: true))
        #expect(!CourseAnswer.matches("かめら", expected: "カメラ", reading: false))
    }
    @Test func kanjiFollowsBothKanaStagesAndCarriesReadingContext() throws {
        let modules = try CourseCatalog.load()
        let first = try #require(modules.firstIndex { $0.id == "kanji.nature" })
        #expect(modules.prefix(first).contains { $0.stage == "Катакана" })
        #expect(!CourseCatalog.unlocked("kanji.nature", modules: modules, progress: .init()))
        let module = modules[first]
        #expect(module.items.count == 7)
        #expect(module.items.allSatisfy { !$0.writingHint.isEmpty && $0.glyph?.alphabet == nil })
        #expect(module.items.first?.readingAlternatives.contains("にち") == true)
    }
}
