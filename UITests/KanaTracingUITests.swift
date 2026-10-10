import XCTest

@MainActor final class KanaTracingUITests: XCTestCase {
    func testCompleteCharacterAdvancesOnlyAfterAllStrokesAndRowSwitchClearsInk() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["open-flashcards"].waitForExistence(timeout: 15))
        app.buttons["open-flashcards"].tap()
        XCTAssertTrue(app.buttons["trace-katakana"].waitForExistence(timeout: 8))
        app.buttons["trace-katakana"].tap()
        XCTAssertTrue(app.buttons["kana-choose-row"].waitForExistence(timeout: 8))
        app.buttons["kana-choose-row"].tap()
        let row = app.buttons["ナ ニ ヌ ネ ノ"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["kana-reading"].label.contains("na"))
        let board = app.descendants(matching: .any)["kana-tracing-board"].firstMatch
        func trace(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            board.coordinate(withNormalizedOffset: CGVector(dx: x1, dy: y1))
                .press(forDuration: 0.05, thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: x2, dy: y2)),
                       withVelocity: .slow, thenHoldForDuration: 0)
        }
        trace(0.169725, 0.404771, 0.842936, 0.358899)
        XCTAssertTrue(app.staticTexts["kana-stroke-count"].label.contains("1/2"))
        XCTAssertFalse(app.buttons["kana-next"].isEnabled)
        trace(0.488624, 0.133028, 0.34633, 0.861193)
        XCTAssertTrue(app.staticTexts["kana-stroke-count"].label.contains("2/2"))
        XCTAssertTrue(app.buttons["kana-next"].isEnabled)
        XCTAssertTrue(app.staticTexts["kana-feedback"].label.contains("Верно"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Kana tracing · accepted character"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try app.screenshot().pngRepresentation.write(to: URL.temporaryDirectory.appendingPathComponent("yohaku-kana-accepted.png"))
        app.buttons["kana-next"].tap()
        XCTAssertTrue(app.staticTexts["kana-reading"].label.contains("ni"))
        XCTAssertTrue(app.staticTexts["kana-stroke-count"].label.contains("0/2"))
        XCTAssertFalse(app.buttons["kana-next"].isEnabled)
        app.buttons["kana-choose-row"].tap()
        app.buttons["ア イ ウ エ オ"].tap()
        XCTAssertTrue(app.staticTexts["kana-stroke-count"].label.contains("0/2"))
        XCTAssertTrue(app.staticTexts["kana-reading"].label.contains("a"))
    }

    func testSeparateAssignmentsWorkWithoutVocabularyAndRejectBadTracing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let library = app.buttons["open-flashcards"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        for alphabet in ["hiragana", "katakana"] {
            let assignment = app.buttons["trace-\(alphabet)"]
            XCTAssertTrue(assignment.waitForExistence(timeout: 8))
            assignment.tap()
            let board = app.descendants(matching: .any)["kana-tracing-board"].firstMatch
            XCTAssertTrue(board.waitForExistence(timeout: 8))
            XCTAssertTrue(app.staticTexts["kana-reading"].label.contains("a"))
            XCTAssertFalse(app.buttons["kana-next"].isEnabled)
            let start = board.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.05))
            let end = board.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
            XCTAssertTrue(app.staticTexts["kana-feedback"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["kana-next"].isEnabled)
            XCTAssertTrue(app.staticTexts["kana-stroke-count"].label.contains("0/"))
            app.buttons["kana-reset"].tap()
            XCTAssertTrue(app.staticTexts["kana-feedback"].label.contains("Пишите"))
            // Hiragana あ first stroke is almost horizontal; this also proves ink
            // reaches UIKit instead of being consumed by the surrounding scroll.
            if alphabet == "hiragana" {
                let a = board.coordinate(withNormalizedOffset: CGVector(dx: 31.01 / 109, dy: 33.0 / 109))
                let b = board.coordinate(withNormalizedOffset: CGVector(dx: 72.38 / 109, dy: 30.0 / 109))
                a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0)
                let accepted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "1/3"),
                                                         object: app.staticTexts["kana-stroke-count"])
                XCTAssertEqual(XCTWaiter.wait(for: [accepted], timeout: 5), .completed)
                XCTAssertFalse(app.buttons["kana-next"].isEnabled)
                app.buttons["kana-reset"].tap()
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Kana tracing · \(alphabet)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            try app.screenshot().pngRepresentation.write(to: URL.temporaryDirectory.appendingPathComponent("yohaku-kana-\(alphabet).png"))
            app.buttons["close-kana-tracing"].tap()
        }
    }
}
