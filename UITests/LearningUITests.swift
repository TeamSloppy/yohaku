import XCTest

@MainActor final class LearningUITests: XCTestCase {
    private func openPractice(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["open-today"].waitForExistence(timeout: 15))
        app.buttons["open-today"].tap()
        let button = app.buttons["extra-practice"]
        for _ in 0..<5 {
            if button.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }
    private func answer(_ app: XCUIApplication) {
        if app.buttons["extra-reading-choice-0"].waitForExistence(timeout: 1) {
            app.buttons["extra-reading-choice-0"].tap(); app.buttons["extra-reading-next"].tap(); return
        }
        XCTAssertTrue(app.buttons["extra-reveal"].waitForExistence(timeout: 5))
        app.buttons["extra-reveal"].tap()
        app.buttons["extra-rate-remembered"].tap()
    }
    func testExtraPracticeResumesAndAllowsAnotherSession() {
        let app = XCUIApplication()
        app.launchEnvironment["YOHHAKU_TEST_VAULT"] = UUID().uuidString
        app.launchArguments = ["--ui-testing", "--learning-fixture"]
        app.launch(); openPractice(app)
        XCTAssertTrue(app.buttons["extra-start"].waitForExistence(timeout: 5)); app.buttons["extra-start"].tap()
        answer(app)
        let second = app.staticTexts["extra-progress"]
        let ready = NSPredicate(format: "label == %@", "2 из 2")
        expectation(for: ready, evaluatedWith: second)
        waitForExpectations(timeout: 8)
        app.terminate(); app.launch(); openPractice(app)
        XCTAssertTrue(second.waitForExistence(timeout: 5)); XCTAssertEqual(second.label, "2 из 2")
        answer(app)
        XCTAssertTrue(app.staticTexts["extra-complete"].waitForExistence(timeout: 5))
        app.buttons["extra-start"].tap(); answer(app); answer(app)
        XCTAssertTrue(app.staticTexts["extra-complete"].waitForExistence(timeout: 5))
    }
    func testAgentPreparationShowsPreviewBeforeStarting() {
        let app = XCUIApplication()
        app.launchEnvironment["YOHHAKU_TEST_VAULT"] = UUID().uuidString
        app.launchArguments = ["--ui-testing", "--learning-fixture"]
        app.launch(); openPractice(app)
        app.buttons["extra-generate"].tap()
        XCTAssertTrue(app.staticTexts["Составлено ИИ из изученных слов"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["extra-progress"].exists)
        app.buttons["extra-start"].tap()
        XCTAssertTrue(app.staticTexts["extra-progress"].waitForExistence(timeout: 8))
        answer(app)
    }
}
