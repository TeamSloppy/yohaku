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
}
