import UIKit
import XCTest

@MainActor final class AgentPanelUITests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testIPadPanelStaysBesideInteractiveNotebookAcrossRotation() throws {
        try requireIPad()
        XCUIDevice.shared.orientation = .portrait
        let app = launchNotebook()
        app.buttons["open-agent"].tap()
        assertSideBySide(app)

        let prompt = app.descendants(matching: .any)["agent-prompt"].firstMatch
        prompt.tap()
        prompt.typeText("Draft question")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertSideBySide(app)

        XCUIDevice.shared.orientation = .landscapeLeft
        assertWindowOrientation(app, landscape: true)
        assertSideBySide(app)
        XCTAssertEqual(prompt.value as? String, "Draft question", "Resizing must preserve the panel's draft")
        prompt.typeText(" continued")
        XCTAssertEqual(prompt.value as? String, "Draft question continued")

        XCUIDevice.shared.orientation = .portrait
        assertWindowOrientation(app, landscape: false)
        assertSideBySide(app)
        XCTAssertEqual(prompt.value as? String, "Draft question continued")
    }

    func testIPadPanelCanCloseAndReopenWithoutLosingNotebook() throws {
        try requireIPad()
        XCUIDevice.shared.orientation = .portrait
        let app = launchNotebook()
        let canvas = app.scrollViews["pencil-canvas"].firstMatch
        app.buttons["open-agent"].tap()
        assertSideBySide(app)
        app.buttons["close-agent"].tap()
        let panel = app.descendants(matching: .any)["agent-side-panel"].firstMatch
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(canvas.isHittable)

        app.buttons["open-agent"].tap()
        assertSideBySide(app)
        let selection = app.buttons["select-region"].firstMatch
        XCTAssertTrue(selection.isHittable, "The editor's selection tool must remain interactive")
        selection.tap()
        // Region selection routes touches through CanvasInteraction instead of PKCanvasView.
        let selecting = NSPredicate { _, _ in !canvas.isHittable && selection.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: selecting, evaluatedWith: app)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["close-agent"].isHittable)
        selection.tap()
        assertSideBySide(app)
    }

    func testIPadPromptAvoidsVisibleDrawingPalette() throws {
        try requireIPad()
        XCUIDevice.shared.orientation = .portrait
        let app = launchNotebook()
        app.buttons["open-agent"].tap()
        assertSideBySide(app)
        let palette = app.descendants(matching: .any)["Drawing-Palette"].firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 8), "The regression requires the native drawing palette to be visible")
        let handle = palette.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Tool palette handle")).firstMatch
        XCTAssertTrue(handle.exists)
        // Establish the original bottom-palette configuration using native element/window bounds.
        let window = mainWindow(app)
        let thickness = min(palette.frame.width, palette.frame.height)
        let bottomDock = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -thickness + handle.frame.height / 2))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: bottomDock)
        let panel = app.descendants(matching: .any)["agent-side-panel"].firstMatch
        let prompt = app.descendants(matching: .any)["agent-prompt"].firstMatch
        let conversation = app.scrollViews["agent-conversation"].firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(prompt.frame.minY, conversation.frame.maxY, "The composer must sit below the conversation")
        let unobstructed = NSPredicate { _, _ in
            palette.exists && palette.frame.width > palette.frame.height
                && palette.frame.maxX > panel.frame.minX && palette.frame.minX < panel.frame.maxX
                && abs(palette.frame.maxY - window.frame.maxY) <= 40
                && !palette.frame.intersects(prompt.frame) && prompt.isHittable
        }
        let result = XCTWaiter.wait(for: [expectation(for: unobstructed, evaluatedWith: app)], timeout: 8)
        saveScreenshot(app, name: "agent-palette-before-input")
        XCTAssertEqual(result, .completed, frameDiagnostics(app, window: window))
        prompt.tap()
        prompt.typeText("Palette-safe draft")
        XCTAssertEqual(prompt.value as? String, "Palette-safe draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertSideBySide(app)
    }

    func testPhoneAgentPresentsModalAndReturnsToNotebookWithoutSending() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Requires an iPhone destination")
        let app = launchNotebook()
        let canvas = app.scrollViews["pencil-canvas"].firstMatch
        app.buttons["open-agent"].tap()
        let prompt = app.descendants(matching: .any)["agent-prompt"].firstMatch
        let close = app.buttons["close-agent"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        XCTAssertTrue(prompt.isHittable)
        XCTAssertTrue(close.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["agent-side-panel"].firstMatch.exists)
        XCTAssertTrue(!canvas.exists || !canvas.isHittable, "The modal agent must cover the notebook")
        prompt.tap()
        prompt.typeText("Unsent phone draft")
        XCTAssertEqual(prompt.value as? String, "Unsent phone draft")
        close.tap()
        let restored = NSPredicate { _, _ in canvas.exists && canvas.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: restored, evaluatedWith: app)], timeout: 8), .completed)
    }

    private func requireIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires an iPad destination")
    }

    private func assertWindowOrientation(_ app: XCUIApplication, landscape: Bool) {
        let window = mainWindow(app)
        let oriented = NSPredicate { _, _ in
            let frame = window.frame
            return landscape ? frame.width > frame.height : frame.height > frame.width
        }
        let result = XCTWaiter.wait(for: [expectation(for: oriented, evaluatedWith: app)], timeout: 8)
        saveScreenshot(app, name: landscape ? "agent-landscape" : "agent-portrait")
        XCTAssertEqual(result, .completed, frameDiagnostics(app, window: window))
    }

    private func mainWindow(_ app: XCUIApplication) -> XCUIElement {
        let window = app.windows.containing(.button, identifier: "open-agent").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8), "The notebook window must contain open-agent")
        XCTAssertTrue(window.scrollViews["pencil-canvas"].firstMatch.exists, "The qualified window must contain the notebook canvas")
        return window
    }

    private func frameDiagnostics(_ app: XCUIApplication, window: XCUIElement) -> String {
        let palette = app.descendants(matching: .any)["Drawing-Palette"].firstMatch
        let prompt = app.descendants(matching: .any)["agent-prompt"].firstMatch
        let panel = app.descendants(matching: .any)["agent-side-panel"].firstMatch
        func frame(_ element: XCUIElement) -> String {
            element.exists ? String(describing: element.frame) : "missing"
        }
        return "main=\(frame(window)), palette=\(frame(palette)), prompt=\(frame(prompt)), panel=\(frame(panel))"
    }

    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).png")
        do {
            try app.screenshot().pngRepresentation.write(to: url)
            print("AgentPanelUITests screenshot: \(url.path)")
        } catch {
            print("AgentPanelUITests could not save \(url.path): \(error)")
        }
    }

    private func launchNotebook() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchAtWorkspaceMenu()
        let notebook = app.buttons["Практика"].firstMatch
        if !notebook.waitForExistence(timeout: 3) {
            let folder = app.buttons["日本語"].firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 10))
            folder.tap()
        }
        XCTAssertTrue(notebook.waitForExistence(timeout: 8))
        notebook.tap()
        XCTAssertTrue(app.scrollViews["pencil-canvas"].firstMatch.waitForExistence(timeout: 8))
        return app
    }

    private func assertSideBySide(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let panel = app.descendants(matching: .any)["agent-side-panel"].firstMatch
        let canvas = app.scrollViews["pencil-canvas"].firstMatch
        let close = app.buttons["close-agent"]
        let prompt = app.descendants(matching: .any)["agent-prompt"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 8), file: file, line: line)
        let beside = NSPredicate { _, _ in
            canvas.isHittable && close.isHittable && prompt.isHittable
                && canvas.frame.width > 0 && panel.frame.width > 0
                && panel.frame.minX >= canvas.frame.maxX - 2
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation(for: beside, evaluatedWith: app)], timeout: 8), .completed,
            "The notebook and trailing panel must remain simultaneously accessible",
            file: file, line: line
        )
    }
}
