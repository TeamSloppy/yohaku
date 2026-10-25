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
        app.launchAtWorkspaceMenu(); openPractice(app)
        XCTAssertTrue(app.buttons["extra-start"].waitForExistence(timeout: 5)); app.buttons["extra-start"].tap()
        answer(app)
        let second = app.staticTexts["extra-progress"]
        let ready = NSPredicate(format: "label == %@", "2 из 2")
        expectation(for: ready, evaluatedWith: second)
        waitForExpectations(timeout: 8)
        app.terminate(); app.launchAtWorkspaceMenu(); openPractice(app)
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
        app.launchAtWorkspaceMenu(); openPractice(app)
        app.buttons["extra-generate"].tap()
        XCTAssertTrue(app.staticTexts["Составлено ИИ из изученных слов"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["extra-progress"].exists)
        app.buttons["extra-start"].tap()
        XCTAssertTrue(app.staticTexts["extra-progress"].waitForExistence(timeout: 8))
        answer(app)
    }
    func testCourseTraceThenRecallAndResume() {
        let app = XCUIApplication()
        app.launchEnvironment["YOHHAKU_TEST_VAULT"] = UUID().uuidString
        app.launchArguments = ["--ui-testing"]
        app.launchAtWorkspaceMenu()
        func openCourse() {
            XCTAssertTrue(app.buttons["open-today"].waitForExistence(timeout: 15)); app.buttons["open-today"].tap()
            for _ in 0..<5 { if app.buttons["open-course"].isHittable { break }; app.swipeUp() }
            app.buttons["open-course"].tap()
        }
        openCourse()
        XCTAssertTrue(app.buttons["course-next-topic"].waitForExistence(timeout: 8))
        app.buttons["course-next-topic"].tap()
        XCTAssertTrue(app.buttons["course-next"].waitForExistence(timeout: 8)); app.buttons["course-next"].tap()
        let board = app.descendants(matching: .any)["kana-tracing-board"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 5)); XCTAssertTrue(board.label.contains("Обведите"))
        app.buttons["course-forgot"].tap()
        XCTAssertTrue(app.staticTexts["Напишите по памяти"].waitForExistence(timeout: 5))
        XCTAssertFalse(board.label.contains("Обведите"))
        let position = app.staticTexts["course-progress"].label
        app.terminate(); app.launchAtWorkspaceMenu(); openCourse()
        XCTAssertTrue(app.buttons["course-resume"].waitForExistence(timeout: 5)); app.buttons["course-resume"].tap()
        XCTAssertTrue(app.staticTexts["course-progress"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["course-progress"].label, position)
        XCTAssertTrue(app.staticTexts["Напишите по памяти"].exists)
    }
    func testCourseTopicIncludesReadingWithOptionalTranslation() {
        let app = XCUIApplication()
        app.launchEnvironment["YOHHAKU_TEST_VAULT"] = UUID().uuidString
        app.launchArguments = ["--ui-testing", "--course-topic-fixture"]
        app.launchAtWorkspaceMenu()
        XCTAssertTrue(app.buttons["open-today"].waitForExistence(timeout: 15)); app.buttons["open-today"].tap()
        for _ in 0..<5 { if app.buttons["open-course"].isHittable { break }; app.swipeUp() }
        app.buttons["open-course"].tap()
        let learn = app.buttons["course-next-topic"]
        XCTAssertTrue(learn.waitForExistence(timeout: 8))
        XCTAssertTrue(learn.exists && learn.isHittable); learn.tap()
        for answer in ["ひと", "ほん"] {
            let response = app.textFields["course-response"]
            XCTAssertTrue(response.waitForExistence(timeout: 8)); response.tap(); response.typeText(answer)
            app.buttons["course-answer"].tap(); app.buttons["course-answer-next"].tap()
        }
        XCTAssertTrue(app.staticTexts["course-reading"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["course-reading"].label.contains("わたしは学生です"))
        XCTAssertTrue(app.buttons["course-reading-translation"].exists)
        app.buttons["course-reading-translation"].tap()
        app.buttons["course-reading-next"].tap()
        XCTAssertTrue(app.staticTexts["course-complete"].waitForExistence(timeout: 8))
    }
    func testDailyCompletionOffersExtraPractice() {
        let app = XCUIApplication()
        app.launchEnvironment["YOHHAKU_TEST_VAULT"] = UUID().uuidString
        app.launchArguments = ["--ui-testing", "--today-study-fixture"]
        app.launchAtWorkspaceMenu()
        XCTAssertTrue(app.buttons["open-today"].waitForExistence(timeout: 15)); app.buttons["open-today"].tap()
        XCTAssertTrue(app.segmentedControls["today-duration"].waitForExistence(timeout: 8))
        app.segmentedControls["today-duration"].buttons.element(boundBy: 0).tap(); app.buttons["today-start"].tap()
        for _ in 0..<3 {
            XCTAssertTrue(app.buttons["reveal-flashcard"].waitForExistence(timeout: 8)); app.buttons["reveal-flashcard"].tap()
            app.buttons["rate-flashcard-Помню"].tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["study-complete"].waitForExistence(timeout: 8))
        app.buttons["daily-extra-practice"].tap()
        XCTAssertTrue(app.buttons["extra-start"].waitForExistence(timeout: 8)); app.buttons["extra-start"].tap()
        XCTAssertTrue(app.staticTexts["extra-progress"].waitForExistence(timeout: 8))
    }
    func testCancelledOrFailedGenerationKeepsReadyPractice() {
        for flag in ["--learning-delay-fixture", "--learning-bad-output-fixture"] {
            let app = XCUIApplication()
            app.launchEnvironment["YOHHAKU_TEST_VAULT"] = UUID().uuidString
            app.launchArguments = ["--ui-testing", "--learning-fixture", flag]
            app.launchAtWorkspaceMenu(); openPractice(app); app.buttons["extra-generate"].tap()
            if flag == "--learning-delay-fixture" {
                XCTAssertTrue(app.buttons["extra-cancel-generation"].waitForExistence(timeout: 5))
                app.buttons["extra-cancel-generation"].tap()
                let unexpected = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: app.staticTexts["Составлено ИИ из изученных слов"])
                unexpected.isInverted = true; waitForExpectations(timeout: 3)
            } else { XCTAssertTrue(app.staticTexts["extra-error"].waitForExistence(timeout: 5)) }
            XCTAssertTrue(app.buttons["extra-start"].isEnabled)
            app.buttons["extra-start"].tap(); XCTAssertTrue(app.staticTexts["extra-progress"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }
    func testHandwrittenOnlyExtraPracticeKeepsOwnAnswerVisible() {
        let app = XCUIApplication()
        app.launchEnvironment["YOHHAKU_TEST_VAULT"] = UUID().uuidString
        app.launchArguments = ["--ui-testing", "--learning-ink-fixture"]
        app.launchAtWorkspaceMenu(); openPractice(app); app.buttons["extra-start"].tap()
        let board = app.descendants(matching: .any)["extra-ink-response"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 8))
        board.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).press(forDuration: 0.1,
            thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7)))
        XCTAssertTrue(app.buttons["extra-ink-response-clear"].isEnabled)
        app.buttons["extra-reveal"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["extra-own-ink"].waitForExistence(timeout: 5))
        let grade = app.buttons["extra-rate-remembered"]
        for _ in 0..<4 { if grade.isHittable { break }; app.swipeUp() }
        grade.tap()
        XCTAssertTrue(app.staticTexts["extra-complete"].waitForExistence(timeout: 5))
    }
}
