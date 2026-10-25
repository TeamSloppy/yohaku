import XCTest

@MainActor final class StudyFeedbackUITests: XCTestCase {
    func testStartsOnTodayAndMenuCanRenameOnlyTitle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-dark"]
        app.launch()
        XCTAssertTrue(app.scrollViews["today-scroll"].waitForExistence(timeout: 15))
        app.buttons["open-workspace-menu"].tap()
        let note = app.buttons["Начало"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 8)); note.press(forDuration: 1)
        app.buttons["rename-file-日本語/Начало.md"].tap()
        let name = app.textFields["file-operation-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertEqual(name.value as? String, "Начало")
        name.tap()
        name.press(forDuration: 1)
        let selectAll = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Select All", "Выбрать всё"])).firstMatch
        if selectAll.waitForExistence(timeout: 2) { selectAll.tap(); name.typeText("Первый урок") }
        else {
            name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Начало".count) + "Первый урок")
        }
        app.buttons["save-file-operation"].tap()
        XCTAssertTrue(app.buttons["Первый урок"].waitForExistence(timeout: 8))
        XCTAssertFalse(name.exists)
        app.buttons["Первый урок"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "Первый урок.md")).firstMatch.waitForExistence(timeout: 8))
    }

    func testLibraryUsesFullHeightScrollAndSoundSettingPersists() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--today-study-fixture", "--ui-testing-dark"]
        app.launch()
        XCTAssertTrue(app.scrollViews["today-scroll"].waitForExistence(timeout: 15))
        app.buttons["open-workspace-menu"].tap()
        app.buttons["open-model-settings"].tap()
        let toggle = app.switches["study-sounds-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        if toggle.value as? String == "0" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 3), .completed)
        XCTAssertFalse(app.buttons["preview-study-sound"].isEnabled)
        app.buttons["close-model-settings"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["open-workspace-menu"].waitForExistence(timeout: 8))
        app.buttons["open-workspace-menu"].tap()
        app.buttons["open-model-settings"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["preview-study-sound"].isEnabled)
        app.buttons["preview-study-sound"].tap()
        app.buttons["close-model-settings"].tap()
        app.buttons["open-flashcards"].tap()
        let library = app.collectionViews["study-library-scroll"]
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        XCTAssertGreaterThan(library.frame.height, app.frame.height * 0.6)
        let header = app.buttons["study-flashcards"].frame
        let kana = app.buttons["trace-hiragana"]
        XCTAssertTrue(kana.isHittable)
        library.swipeUp()
        XCTAssertEqual(app.buttons["study-flashcards"].frame, header)
        XCTAssertFalse(kana.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Library full scroll"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
