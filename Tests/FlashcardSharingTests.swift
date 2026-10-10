import PencilKit
import Testing
import UIKit
@testable import Yohaku

struct FlashcardSharingTests {
    @Test func sharesLearningContentWithoutPrivateSourceOrProgress() throws {
        var card = Flashcard(japanese: " 猫 \n", reading: "ねこ", translation: "кошка", example: "猫がいます。", note: "Домашнее животное")
        card.pitchAccent = "1"
        card.sourcePath = "private/diary.md"
        card.sourceExcerpt = "Личный дневник"
        card.failedReviews = 42
        card.pronunciationAudio = FlashcardAudio(relativePath: "study-audio/private.m4a", fileName: "private.m4a", source: .sourceClip)
        let text = try #require(FlashcardSharing.text(for: card))
        #expect(text == "猫\n\nねこ\n\nкошка\n\nPitch accent: 1\n\nПример: 猫がいます。\n\nЗаметка: Домашнее животное")
        #expect(!text.contains("private"))
        #expect(!text.contains("Личный дневник"))
        #expect(!text.contains("42"))
    }

    @Test @MainActor func handwritingOnlyCardsExportRealImageWithoutIncompleteText() throws {
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 160, y: 80)]
        let path = PKStrokePath(controlPoints: points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 6, height: 6), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date())
        let ink = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)]).dataRepresentation()
        var card = Flashcard(japanese: "", translation: "")
        card.handwriting = FlashcardHandwriting(japanese: ink, reading: ink, translation: ink)
        #expect(FlashcardSharing.text(for: card) == nil)
        let image = try #require(FlashcardSharing.image(for: card))
        let png = try #require(image.pngData())
        Attachment.record(png, named: "handwritten-shared-card.png")
        try png.write(to: URL.temporaryDirectory.appendingPathComponent("yohaku-shared-ink.png"))
        #expect(UIImage(data: png)?.size.width == 1080)
        var withoutInk = card
        withoutInk.handwriting = nil
        let blank = try #require(FlashcardSharing.image(for: withoutInk))
        #expect(image.size.height > blank.size.height)
        #expect(png != blank.pngData())
    }

    @Test @MainActor func longContentExpandsExportAndInvalidInkDoesNotBreakTextCard() throws {
        var card = Flashcard(japanese: "食べる", translation: "есть")
        let short = try #require(FlashcardSharing.image(for: card))
        Attachment.record(try #require(short.pngData()), named: "text-shared-card.png")
        try short.pngData()?.write(to: URL.temporaryDirectory.appendingPathComponent("yohaku-shared-text.png"))
        card.example = String(repeating: "毎朝パンを食べる。 ", count: 25)
        card.note = String(repeating: "Длинное пояснение без обрезки. ", count: 15)
        card.handwriting = FlashcardHandwriting(japanese: Data([0, 1, 2]))
        let long = try #require(FlashcardSharing.image(for: card))
        Attachment.record(try #require(long.pngData()), named: "long-shared-card.png")
        try long.pngData()?.write(to: URL.temporaryDirectory.appendingPathComponent("yohaku-shared-long.png"))
        #expect(long.size.width == short.size.width)
        #expect(long.size.height > short.size.height * 2)
        #expect(long.pngData() != nil)
        #expect(FlashcardSharing.text(for: card)?.contains(card.example.trimmingCharacters(in: .whitespacesAndNewlines)) == true)
    }
}
