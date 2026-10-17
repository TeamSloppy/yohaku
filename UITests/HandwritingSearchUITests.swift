import XCTest

final class HandwritingSearchUITests: XCTestCase {
    @MainActor func testAuthoredNotebookTextSearchOpensExactSource() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15)); search.tap(); search.typeText("はじめましょう")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "knowledge-result-")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        try saveScreenshot(app, name: "knowledge-search-results")
        XCTAssertTrue(result.label.contains("日本語/Практика.studycanvas")); result.tap()
        XCTAssertTrue(app.scrollViews["pencil-canvas"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["source-region-highlight"].waitForExistence(timeout: 8))
    }
    @MainActor func testExplicitRecognitionLanguageEmptyAndDismiss() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let menu = app.buttons["handwriting-recognition-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15)); menu.tap()
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Распознать текущую страницу", "Recognize current page"])).firstMatch.tap()
        let run = app.buttons["handwriting-run"]
        XCTAssertTrue(run.waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["handwriting-loading"].exists)
        let language = app.buttons["handwriting-language"]
        XCTAssertTrue(language.exists); language.tap()
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Английский", "English"])).firstMatch.tap()
        run.tap()
        let status = app.staticTexts["handwriting-status"]
        let empty = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label IN %@", ["Текст не найден в выбранном фрагменте.", "No text found in the selected fragment."]), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 20), .completed)
        // The fixture contains an authored text card; OCR deliberately processes only ink/images.
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "handwriting-observation-")).count, 0)
        try saveScreenshot(app, name: "handwriting-empty-result")
        app.buttons["handwriting-done"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Распознать текущую страницу", "Recognize current page"])).firstMatch.tap()
        XCTAssertTrue(run.waitForExistence(timeout: 5)); app.buttons["handwriting-done"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
    }
    @MainActor private func saveScreenshot(_ app: XCUIApplication, name: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).png")
        try app.screenshot().pngRepresentation.write(to: url)
        print("UI screenshot: \(url.path)")
    }
}
