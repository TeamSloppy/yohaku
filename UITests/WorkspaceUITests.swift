import XCTest

@MainActor final class WorkspaceUITests: XCTestCase {
    func testHuggingFaceCatalogAndDeviceProfileControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let settings = app.buttons["Модели и настройки"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap()
        let hub = app.buttons["open-huggingface-catalog"]
        XCTAssertTrue(hub.waitForExistence(timeout: 8))
        if !hub.isHittable { app.swipeUp() }
        hub.tap()
        let all = app.buttons["Каталог HF"]
        XCTAssertTrue(all.waitForExistence(timeout: 8)); all.tap()
        XCTAssertTrue(app.switches["Только MLX-версии"].waitForExistence(timeout: 5))
        let access = app.buttons["Доступ Hugging Face"]
        XCTAssertTrue(access.exists); access.tap()
        XCTAssertTrue(app.secureTextFields["hf_…"].waitForExistence(timeout: 5))
        app.buttons["Отмена"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Hugging Face catalog"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testSelectionToAgentAndMarkdownModes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let selection = app.buttons["select-region"]
        XCTAssertTrue(selection.waitForExistence(timeout: 15))
        selection.tap()
        let canvas = app.scrollViews["pencil-canvas"]
        XCTAssertTrue(canvas.exists)
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.05))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.25))
        start.press(forDuration: 0.15, thenDragTo: end)
        XCTAssertTrue(app.staticTexts["Выделенный фрагмент"].waitForExistence(timeout: 8))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Selection to agent"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["Закрыть помощника"].tap()
        app.buttons.matching(identifier: "Начало").firstMatch.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        let original = editor.value as? String
        XCTAssertTrue(original?.contains("少しずつ") == true)
        app.buttons["Live Preview"].tap()
        XCTAssertEqual(editor.value as? String, original)
        app.buttons["Исходник"].tap()
        XCTAssertEqual(editor.value as? String, original)
        let markdown = XCTAttachment(screenshot: app.screenshot()); markdown.name = "Markdown live preview"; markdown.lifetime = .keepAlways; add(markdown)
    }
}
