import XCTest

@MainActor final class StudyReminderUITests: XCTestCase {
    func testReminderSettingsOpenFromEmptyLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let library = app.buttons["open-flashcards"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        let reminders = app.buttons["study-reminder-settings"]
        XCTAssertTrue(reminders.waitForExistence(timeout: 8))
        reminders.tap()
        XCTAssertTrue(app.switches["study-reminder-enabled"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.datePickers["study-reminder-time"].exists)
        XCTAssertTrue(app.staticTexts["Новое слово каждый час"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Reminder settings and hourly widget"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
