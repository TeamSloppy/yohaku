import Foundation
import Testing
import UserNotifications
@testable import Yohaku

struct StudyCompanionTests {
    private func card(_ word: String) -> StudyWidgetCard {
        StudyWidgetCard(id: UUID(), japanese: word, reading: "", translation: word)
    }

    @Test func hourlyRotationStaysStableAndVisitsEveryCard() throws {
        let cards = [card("猫"), card("犬"), card("鳥")]
        let snapshot = StudyWidgetSnapshot(cards: cards)
        let hour = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(snapshot.card(at: hour) == snapshot.card(at: hour.addingTimeInterval(3599)))
        let rotation = (0..<3).compactMap { snapshot.card(at: hour.addingTimeInterval(Double($0) * 3600))?.id }
        #expect(Set(rotation) == Set(cards.map(\.id)))
        #expect(snapshot.card(at: hour) == snapshot.card(at: hour.addingTimeInterval(3 * 3600)))
        #expect(StudyWidgetSnapshot().card(at: hour) == nil)
    }

    @Test func timelineStartsNowThenAtHourBoundariesAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-01T05:25:00Z"))
        let dates = StudyWidgetSnapshot.entryDates(from: now, calendar: calendar)
        #expect(dates.count == 49)
        #expect(dates.first == now)
        #expect(dates[1].timeIntervalSince(now) == 35 * 60)
        for index in 1..<dates.count {
            #expect(calendar.component(.minute, from: dates[index]) == 0)
            #expect(dates[index] > dates[index - 1])
        }
    }

    @Test func sharedSnapshotPreservesInkAndClearsOnVaultSwitch() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("widget.json")
        #expect(StudyWidgetStorage.load(from: url).cards.isEmpty)
        var ink = card("")
        ink.japaneseImage = Data([1, 2, 3])
        let snapshot = StudyWidgetSnapshot(cards: [ink])
        try StudyWidgetStorage.save(snapshot, to: url)
        #expect(StudyWidgetStorage.load(from: url) == snapshot)
        try StudyWidgetStorage.save(StudyWidgetSnapshot(), to: url)
        #expect(StudyWidgetStorage.load(from: url).cards.isEmpty)
        try Data("corrupted".utf8).write(to: url)
        #expect(StudyWidgetStorage.load(from: url).cards.isEmpty)
    }

    @Test @MainActor func widgetURLRequestsLibraryAndRejectsUnrelatedURLs() throws {
        let companion = StudyCompanion(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(!companion.handle(try #require(URL(string: "https://example.com/study"))))
        #expect(!companion.handle(try #require(URL(string: "yohaku://other"))))
        #expect(companion.openLibraryRequest == 0)
        #expect(companion.handle(StudyWidgetStorage.studyURL))
        #expect(companion.openLibraryRequest == 1)
        companion.requestLibrary()
        #expect(companion.openLibraryRequest == 2)
    }

    @Test func dailyReminderRepeatsAtTenAndReusesIdentifier() throws {
        let request = StudyReminderTime().request()
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.repeats)
        #expect(trigger.dateComponents.hour == 10)
        #expect(trigger.dateComponents.minute == 0)
        #expect(trigger.dateComponents.timeZone == nil)
        #expect(request.content.title == "Пора повторить слова")
        #expect(request.identifier == StudyReminderTime(hour: 18, minute: 30).request().identifier)
        #expect(trigger.nextTriggerDate() != nil)
    }

    @Test @MainActor func storePublishesOnlySavedChangesAndCurrentVault() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var published: [[Flashcard]] = []
        let store = FlashcardStore { published.append($0) }
        let word = Flashcard(japanese: "猫", translation: "кошка")
        #expect(!(await store.add(word)))
        #expect(published.isEmpty)
        await store.open(vaultRoot: root.appendingPathComponent("first"))
        #expect(published.last == [])
        #expect(await store.add(word))
        #expect(published.last == [word])
        await store.review(id: word.id, rating: .remembered)
        #expect(published.last?.first?.lastRating == .remembered)
        await store.open(vaultRoot: root.appendingPathComponent("second"))
        #expect(published.last == [])
        await store.open(vaultRoot: root.appendingPathComponent("first"))
        #expect(published.last?.count == 1)
        await store.delete(id: word.id)
        #expect(published.last == [])
    }
}
