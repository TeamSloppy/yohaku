import Foundation
import Observation
import PencilKit
import UserNotifications
import WidgetKit

struct StudyReminderTime: Equatable, Sendable {
    var hour = 10
    var minute = 0

    var dateComponents: DateComponents { DateComponents(hour: hour, minute: minute) }

    func request() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Пора повторить слова"
        content.body = "Несколько минут практики помогут запомнить слова. Откройте карточки в Yohaku."
        content.sound = .default
        content.threadIdentifier = "study"
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        return UNNotificationRequest(identifier: StudyCompanion.reminderID, content: content, trigger: trigger)
    }
}

@MainActor @Observable final class StudyCompanion: NSObject, UNUserNotificationCenterDelegate {
    static let shared = StudyCompanion()
    nonisolated static let reminderID = "yohaku-study-daily"
    private(set) var enabled: Bool
    private(set) var time: StudyReminderTime
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var isUpdating = false
    private(set) var openLibraryRequest = 0
    private(set) var error: String?
    private var hasCards = false
    private var lastSnapshot: StudyWidgetSnapshot?
    private let defaults: UserDefaults
    private let center = UNUserNotificationCenter.current()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "study-reminder-enabled") as? Bool ?? true
        time = StudyReminderTime(
            hour: defaults.object(forKey: "study-reminder-hour") as? Int ?? 10,
            minute: defaults.object(forKey: "study-reminder-minute") as? Int ?? 0
        )
        super.init()
    }

    func activate() { center.delegate = self }

    func requestLibrary() { openLibraryRequest += 1 }

    @discardableResult func handle(_ url: URL) -> Bool {
        guard url.scheme == "yohaku", url.host == "study" else { return false }
        requestLibrary()
        return true
    }

    func updateCards(_ cards: [Flashcard]) async {
        // Unit/UI test vaults must not replace the user's widget or notification schedule.
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        hasCards = !cards.isEmpty
        let snapshot = StudyWidgetSnapshot(cards: cards.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            StudyWidgetCard(id: $0.id, japanese: $0.japanese, reading: $0.reading, translation: $0.translation,
                            japaneseImage: Self.image($0.handwriting?.japanese),
                            readingImage: Self.image($0.handwriting?.reading),
                            translationImage: Self.image($0.handwriting?.translation))
        })
        if snapshot != lastSnapshot {
            do {
                try StudyWidgetStorage.save(snapshot)
                lastSnapshot = snapshot
                WidgetCenter.shared.reloadTimelines(ofKind: StudyWidgetStorage.kind)
                error = nil
            } catch { self.error = "Не удалось обновить виджет: \(error.localizedDescription)" }
        }
        await reconcile(requestPermission: hasCards)
    }

    func setEnabled(_ value: Bool) async {
        enabled = value
        defaults.set(value, forKey: "study-reminder-enabled")
        await reconcile(requestPermission: value)
    }

    func setTime(_ date: Date) async {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        time = StudyReminderTime(hour: components.hour ?? 10, minute: components.minute ?? 0)
        defaults.set(time.hour, forKey: "study-reminder-hour")
        defaults.set(time.minute, forKey: "study-reminder-minute")
        await reconcile()
    }

    func reconcile(requestPermission: Bool = false) async {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        isUpdating = true
        defer { isUpdating = false }
        authorization = await center.notificationSettings().authorizationStatus
        do {
            if requestPermission, enabled, authorization == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                authorization = await center.notificationSettings().authorizationStatus
            }
            guard enabled, hasCards, authorization == .authorized || authorization == .provisional else {
                center.removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
                center.removeDeliveredNotifications(withIdentifiers: [Self.reminderID])
                return
            }
            try await center.add(time.request())
        } catch { self.error = "Не удалось настроить напоминание: \(error.localizedDescription)" }
    }

    private static func image(_ data: Data?) -> Data? {
        guard let data, let drawing = try? PKDrawing(data: data), !drawing.bounds.isEmpty else { return nil }
        let bounds = drawing.bounds.insetBy(dx: -6, dy: -6)
        return drawing.image(from: bounds, scale: min(2, 480 / max(bounds.width, 1))).pngData()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == Self.reminderID,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in Self.shared.requestLibrary() }
        }
        completionHandler()
    }
}
