import Foundation
import Testing
import PencilKit
import UIKit
@testable import StudyIntelligence
@testable import Yohaku

struct FlashcardSchedulerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func ratingsProduceDeterministicIntervals() {
        let card = Flashcard(japanese: "食べる", translation: "есть")

        let forgotten = FlashcardScheduler.review(card, rating: .forgot, now: now)
        #expect(forgotten.intervalDays == 0)
        #expect(forgotten.failedReviews == 1)
        #expect(forgotten.dueAt == now.addingTimeInterval(600))
        #expect(forgotten.lastRating == .forgot)
        #expect(forgotten.lastReviewAt == now)

        let hard = FlashcardScheduler.review(card, rating: .hard, now: now)
        #expect(hard.intervalDays == 1)
        #expect(hard.successfulReviews == 1)

        let remembered = FlashcardScheduler.review(card, rating: .remembered, now: now)
        #expect(remembered.intervalDays == 3)
        #expect(remembered.successfulReviews == 1)
    }

    @Test func practiceRotatesThroughActiveRecallModes() {
        var card = Flashcard(
            japanese: "食べる",
            translation: "есть",
            example: "毎朝パンを食べる。"
        )
        #expect(FlashcardPracticeQueue.exercise(for: card).mode == .recognition)

        card.successfulReviews = 1
        #expect(FlashcardPracticeQueue.exercise(for: card).mode == .production)

        card.successfulReviews = 2
        let exercise = FlashcardPracticeQueue.exercise(for: card)
        #expect(exercise.mode == .cloze)
        #expect(exercise.prompt == "毎朝パンを＿＿＿。")
    }

    @Test func legacyCardsDecodeWithoutSourceMetadata() throws {
        let data = Data(#"[{"id":"9D9CFA6D-A2D1-470C-9B4B-8C4CE8FF179B","japanese":"猫","translation":"кошка","reading":"ねこ","example":"","note":"","createdAt":0,"dueAt":0,"intervalDays":0,"successfulReviews":0,"failedReviews":0}]"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let card = try #require(decoder.decode([Flashcard].self, from: data).first)
        #expect(card.sourcePath == nil)
        #expect(card.lastRating == nil)
        #expect(card.pitchAccent == nil)
        #expect(card.pronunciationAudio == nil)
        #expect(card.handwriting == nil)
    }

    @Test @MainActor func handwrittenCardsPersistAndJoinThePracticePool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FlashcardStore()
        await store.open(vaultRoot: root)

        var draft = FlashcardDraft()
        #expect(!draft.isValid)
        draft.handwriting.japanese = ink(at: 20)
        #expect(!draft.isValid)
        draft.handwriting.reading = ink(at: 50)
        draft.handwriting.translation = ink(at: 80)
        #expect(draft.isValid)
        let card = draft.makeCard()
        #expect(await store.add(card))

        let restored = FlashcardStore()
        await restored.open(vaultRoot: root)
        #expect(restored.cards == [card])
        #expect(restored.dueCards.map(\.id) == [card.id])
        let recognition = try #require(FlashcardPracticeQueue.exercises(for: restored.dueCards).first)
        #expect(recognition.mode == .recognition)
        #expect(recognition.promptHandwriting == draft.handwriting.japanese)
        let restoredInk = try PKDrawing(data: #require(restored.cards.first?.handwriting?.japanese))
        #expect(restoredInk.strokes.count == 1)

        await restored.review(id: card.id, rating: .remembered)
        let reviewed = try #require(restored.cards.first)
        let production = FlashcardPracticeQueue.exercise(for: reviewed)
        #expect(production.mode == .production)
        #expect(production.promptHandwriting == draft.handwriting.translation)

        var edited = FlashcardDraft(card: reviewed)
        edited.handwriting.reading = ink(at: 100)
        let updated = edited.makeCard()
        #expect(updated.id == card.id)
        #expect(updated.dueAt == reviewed.dueAt)
        #expect(updated.successfulReviews == 1)
        #expect(await restored.update(updated))
        let reloaded = FlashcardStore()
        await reloaded.open(vaultRoot: root)
        #expect(reloaded.cards == [updated])

        await reloaded.add([updated, Flashcard(japanese: "", translation: "", handwriting: draft.handwriting)])
        #expect(reloaded.cards.count == 2)
    }

    @Test @MainActor func mixedInputAndClearingHandwritingPreserveTextCards() {
        var draft = FlashcardDraft(japanese: "猫")
        draft.handwriting.translation = ink(at: 20)
        #expect(draft.isValid)
        draft.handwriting.translation = nil
        #expect(!draft.isValid)
        draft.translation = "кошка"
        #expect(draft.isValid)
        #expect(draft.makeCard().handwriting == nil)
    }

    @Test @MainActor func failedSaveDoesNotAddCardToPool() async {
        let store = FlashcardStore()
        #expect(await store.add(Flashcard(japanese: "猫", translation: "кошка")) == false)
        #expect(store.cards.isEmpty)
        #expect(store.error != nil)
    }

    @Test @MainActor func handwritingPreviewKeepsDarkInkOnWhitePaperInDarkMode() throws {
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            image = FlashcardInkRenderer.image(from: ink(at: 20))
        }
        let bitmap = try #require(image?.cgImage)
        let width = bitmap.width, height = bitmap.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let darkPixels = try pixels.withUnsafeMutableBytes { bytes -> Int in
            let context = try #require(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(rect)
            context.draw(bitmap, in: rect)
            let rgba = bytes.bindMemory(to: UInt8.self)
            return stride(from: 0, to: rgba.count, by: 4).filter {
                rgba[$0] < 128 && rgba[$0 + 1] < 128 && rgba[$0 + 2] < 128
            }.count
        }
        #expect(darkPixels > 10)
    }

    @MainActor private func ink(at y: CGFloat) -> Data {
        let points = [CGPoint(x: 20, y: y), CGPoint(x: 90, y: y + 30)].map {
            PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        return PKDrawing(strokes: [stroke]).dataRepresentation()
    }

    @Test @MainActor func storePersistsCRUDAndDeduplicatesGeneratedCards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FlashcardStore()
        await store.open(vaultRoot: root)
        let first = Flashcard(japanese: "猫", translation: "кошка", sourcePath: "日本語/Начало.md", sourceExcerpt: "猫がいます。")
        await store.add([first, Flashcard(japanese: "猫", translation: "кошка")])
        #expect(store.cards.count == 1)

        var edited = try #require(store.cards.first)
        edited.note = "животное"
        await store.update(edited)

        let restored = FlashcardStore()
        await restored.open(vaultRoot: root)
        #expect(restored.cards == [edited])
        await restored.delete(id: edited.id)
        #expect(restored.cards.isEmpty)
    }

    @Test @MainActor func storeImportsAndRemovesPronunciationAudioInsideVault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        try Data([0x00, 0x01, 0x02]).write(to: source)

        let store = FlashcardStore()
        await store.open(vaultRoot: root)
        let audio = try await store.importPronunciationAudio(from: source, source: .nativeSpeaker)
        let copiedURL = try #require(store.pronunciationAudioURL(for: audio))

        #expect(audio.fileName == source.lastPathComponent)
        #expect(audio.source == .nativeSpeaker)
        #expect(try Data(contentsOf: copiedURL) == Data([0x00, 0x01, 0x02]))

        await store.deletePronunciationAudio(audio)
        #expect(!FileManager.default.fileExists(atPath: copiedURL.path))
    }
}

struct JapanesePronunciationLinksTests {
    @Test func linksPreserveJapaneseTermAndTargetExpectedServices() {
        let term = "電話をかける"
        #expect(JapanesePronunciationLinks.forvo(term).host == "forvo.com")
        #expect(JapanesePronunciationLinks.forvo(term).path.contains(term))
        #expect(JapanesePronunciationLinks.youGlish(term).host == "youglish.com")
        #expect(JapanesePronunciationLinks.youGlish(term).path.contains(term))
    }

    @Test func forvoRequestEncodesJapaneseAndLimitsToBestJapaneseResult() throws {
        let url = try #require(ForvoAPI.requestURL(term: "電話を かける", key: "secret"))
        #expect(url.host == "apifree.forvo.com")
        #expect(url.absoluteString.contains("%E9%9B%BB%E8%A9%B1"))
        #expect(url.path.contains("/language/ja/"))
        #expect(url.path.hasSuffix("/limit/1"))
    }

    @Test func previousAudioMetadataDecodesWithoutNewAttributionFields() throws {
        let data = Data(#"{"relativePath":"study-audio/sample.mp3","fileName":"sample.mp3","source":"nativeSpeaker"}"#.utf8)
        let audio = try JSONDecoder().decode(FlashcardAudio.self, from: data)
        #expect(audio.attribution == nil)
        #expect(audio.sourceURL == nil)
    }

    @Test func localPronunciationScoringRewardsMatchingPitchAndRhythm() {
        let reference = AppleAudioFeatures(duration: 1.0, normalizedPitchContour: [0, 1, 0, -1])
        let matching = LocalPronunciationScoring.score(
            reference: reference,
            recording: reference,
            recognizedText: "猫がいます",
            expectedTexts: ["猫がいます。"]
        )
        let different = LocalPronunciationScoring.score(
            reference: reference,
            recording: AppleAudioFeatures(duration: 2.0, normalizedPitchContour: [0, -2, 0, 2]),
            recognizedText: "犬です",
            expectedTexts: ["猫がいます。"]
        )
        #expect(matching.overall == 100)
        #expect(matching.pitchContour == 100)
        #expect(matching.rhythm == 100)
        #expect(different.overall < matching.overall)
        #expect(different.pitchContour < matching.pitchContour)
        #expect(different.rhythm < matching.rhythm)
    }
}

struct FlashcardGenerationTests {
    @Test func parserExtractsValidUniqueCardsAndHonorsLimit() throws {
        let response = """
        ```json
        [
          {"japanese":"猫","reading":"ねこ","translation":"кошка","example":"猫がいます。","note":""},
          {"japanese":"猫","reading":"ねこ","translation":"кошка","example":"duplicate","note":""},
          {"japanese":"犬","reading":"いぬ","translation":"собака","example":"犬がいます。","note":""}
        ]
        ```
        """
        let cards = try FlashcardGenerationParser.parse(response, limit: 10)
        #expect(cards.map(\.japanese) == ["猫", "犬"])
        #expect(try FlashcardGenerationParser.parse(response, limit: 1).count == 1)
    }

    @Test func parserRejectsNonJSONAndDropsInvalidCards() throws {
        #expect(throws: Error.self) { try FlashcardGenerationParser.parse("нет массива", limit: 10) }
        let response = #"[{"japanese":"","reading":"","translation":"пусто","example":"","note":""}]"#
        #expect(try FlashcardGenerationParser.parse(response, limit: 10).isEmpty)
    }
}
