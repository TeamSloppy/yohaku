import XCTest

@MainActor final class WorkspaceUITests: XCTestCase {
    func testHuggingFaceCatalogAndDeviceProfileControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let settings = app.buttons["open-model-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap()
        let hub = app.buttons["open-huggingface-catalog"]
        XCTAssertTrue(hub.waitForExistence(timeout: 8))
        if !hub.isHittable { app.swipeUp() }
        hub.tap()
        let all = app.buttons["model-browser-mode-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 8)); all.tap()
        XCTAssertTrue(app.switches["model-browser-mlx-only"].waitForExistence(timeout: 5))
        let access = app.buttons["open-huggingface-access"]
        XCTAssertTrue(access.exists); access.tap()
        XCTAssertTrue(app.secureTextFields["huggingface-token"].waitForExistence(timeout: 5))
        app.buttons["cancel-huggingface-access"].tap()
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
        XCTAssertTrue(app.staticTexts["agent-source-context"].waitForExistence(timeout: 8))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Selection to agent"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["close-agent"].tap()
        app.buttons.matching(identifier: "Начало").firstMatch.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        let original = editor.value as? String
        XCTAssertTrue(original?.contains("少しずつ") == true)
        app.buttons["toggle-markdown-source-mode"].tap()
        XCTAssertEqual(editor.value as? String, original)
        app.buttons["toggle-markdown-source-mode"].tap()
        XCTAssertEqual(editor.value as? String, original)
        let markdown = XCTAttachment(screenshot: app.screenshot()); markdown.name = "Markdown live preview"; markdown.lifetime = .keepAlways; add(markdown)
    }
    func testMarkdownLinkCompletionFiltersAndInsertsLink() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let note = app.buttons.matching(identifier: "Начало").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15)); note.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8)); editor.tap()
        editor.typeText("[[прак")
        XCTAssertTrue((editor.value as? String)?.contains("[[прак]]") == true, "Editor value after paired input: \(String(describing: editor.value))")
        let suggestion = app.buttons["markdown-link-completion-日本語/Практика.studycanvas"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), app.debugDescription); suggestion.tap()
        let value = editor.value as? String
        XCTAssertTrue(value?.contains("[Практика](%D0%9F%D1%80%D0%B0%D0%BA%D1%82%D0%B8%D0%BA%D0%B0.studycanvas)") == true)
    }
    func testMarkdownEditSurvivesLeavingAndReturningToPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let note = app.buttons.matching(identifier: "Начало").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15)); note.tap()
        var editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        let initial = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(initial.contains("[Открыть тетрадь](Практика.studycanvas)"))

        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        editor.typeText(" сохранено-после-возврата")
        XCTAssertTrue((editor.value as? String)?.contains("сохранено-после-возврата") == true)
        app.buttons.matching(identifier: "Практика").firstMatch.tap()
        XCTAssertTrue(app.scrollViews["pencil-canvas"].waitForExistence(timeout: 8))
        note.tap()

        editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        let restored = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(restored.contains("сохранено-после-возврата"))
        XCTAssertTrue(restored.contains("[Открыть тетрадь](Практика.studycanvas)"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Markdown after returning to page"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testMarkdownSlashCommandPopupInsertsCheckbox() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let note = app.buttons.matching(identifier: "Начало").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15)); note.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        editor.typeText("\n/")

        let checkbox = app.buttons["markdown-slash-command-checkbox"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["markdown-slash-command-link"].exists)
        XCTAssertTrue(app.buttons["markdown-slash-command-table"].exists)
        checkbox.tap()
        XCTAssertTrue((editor.value as? String)?.contains("- [ ] ") == true)
    }
}
