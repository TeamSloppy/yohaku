import XCTest

@MainActor final class WorkspaceUITests: XCTestCase {
    private func openTestNotebook(_ app: XCUIApplication) throws {
        if app.scrollViews["pencil-canvas"].waitForExistence(timeout: 2) { return }
        let notebook = app.buttons.matching(identifier: "Практика").firstMatch
        if !notebook.exists {
            let folder = app.buttons["日本語"].firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 10))
            folder.tap()
        }
        XCTAssertTrue(notebook.waitForExistence(timeout: 8))
        notebook.tap()
        XCTAssertTrue(app.scrollViews["pencil-canvas"].waitForExistence(timeout: 8))
    }
    func testMarkdownSourceConfirmationPreviewAndAcceptance() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--markdown-study-fixture"]; app.launch()
        let source = app.buttons["Источник"].firstMatch
        if !source.waitForExistence(timeout: 3) { app.buttons["日本語"].firstMatch.tap() }
        XCTAssertTrue(source.waitForExistence(timeout: 8)); source.tap()
        app.buttons["prepare-markdown-study"].tap()
        let excerpt = app.staticTexts["markdown-study-excerpt"]
        XCTAssertTrue(excerpt.waitForExistence(timeout: 8)); XCTAssertEqual(excerpt.label, "猫はかわいい。")
        XCTAssertTrue(app.staticTexts["markdown-study-provider"].exists)
        XCTAssertFalse(app.buttons["save-generated-flashcards"].exists)
        app.buttons["request-source-flashcards"].tap()
        guard app.staticTexts["source-quote-0"].waitForExistence(timeout: 8) else {
            let text = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            let buttons = app.buttons.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: " | ")
            XCTFail("Source preview absent. Text: \(text). Buttons: \(buttons)"); return
        }
        XCTAssertTrue(app.staticTexts["Придуманный пример"].exists)
        app.buttons["save-generated-flashcards"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["save-generated-flashcards"])
        guard XCTWaiter.wait(for: [closed], timeout: 8) == .completed else { XCTFail("Preview did not close after acceptance"); return }
        if !app.buttons["open-flashcards"].exists { app.buttons["BackButton"].tap() }
        try openStudyLibrary(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "flashcard-row-", "猫")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["猫はかわいい。"].waitForExistence(timeout: 8))
    }

    func testSavedMaterialRestartAcceptRejectAndStale() throws {
        for outcome in ["accept", "reject", "stale", "recovery"] {
            let app = XCUIApplication()
            app.launchEnvironment["YOHHAKU_TEST_VAULT"] = UUID().uuidString
            app.launchArguments = ["--ui-testing", "--markdown-study-fixture"]; app.launch()
            let source = app.buttons["Источник"].firstMatch
            if !source.waitForExistence(timeout: 3) { app.buttons["日本語"].firstMatch.tap() }
            XCTAssertTrue(source.waitForExistence(timeout: 8)); source.tap()
            app.buttons["prepare-markdown-study"].tap(); app.buttons["request-source-flashcards"].tap()
            XCTAssertTrue(app.staticTexts["source-quote-0"].waitForExistence(timeout: 8))
            app.buttons.matching(NSPredicate(format: "label IN %@", ["Закрыть", "Close"])).firstMatch.tap()
            app.terminate()
            if outcome == "stale" { app.launchArguments.append("--study-material-stale-fixture") }
            if outcome == "recovery" { app.launchArguments.append("--study-material-recovery-fixture") }
            app.launch()
            if !app.buttons["open-flashcards"].waitForExistence(timeout: 3) { app.buttons["BackButton"].tap() }
            try openStudyLibrary(app)
            app.buttons["open-study-materials"].tap()
            if outcome == "recovery" {
                let cancel = app.buttons["cancel-study-acceptance"]
                XCTAssertTrue(cancel.waitForExistence(timeout: 8)); cancel.tap()
                let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cancel)
                XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 8), .completed)
            }
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "study-material-")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
            let accept = app.buttons["accept-study-material"]
            XCTAssertTrue(accept.waitForExistence(timeout: 8))
            if outcome == "stale" {
                XCTAssertFalse(accept.isEnabled)
                XCTAssertTrue(app.staticTexts["study-material-status"].label.contains("Источник изменился"))
            } else {
                if outcome == "reject" { app.swipeUp() }
                let action = app.buttons[outcome == "reject" ? "reject-study-material" : "accept-study-material"]
                XCTAssertTrue(action.waitForExistence(timeout: 8)); action.tap()
                XCTAssertTrue(row.waitForExistence(timeout: 8))
                XCTAssertTrue(row.label.contains(outcome == "reject" ? "Отклонено" : "Добавлено"))
            }
            app.terminate()
        }
    }

    private func correctCanvasTranscription(_ app: XCUIApplication, text: XCUIElement) {
        text.tap()
        let keyboardContinue = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Continue")).firstMatch
        if keyboardContinue.waitForExistence(timeout: 1) { keyboardContinue.tap(); text.tap() }
        text.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: text.frame.width - 18, dy: 18)).tap()
        text.typeText("かわいい。")
        XCTAssertEqual(text.value as? String, "猫はかわいい。")
    }
    func testCanvasPageRecognitionCorrectionAndAcceptance() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--canvas-study-fixture"]; app.launch()
        try openTestNotebook(app)
        app.buttons["prepare-canvas-study"].tap(); app.buttons["prepare-canvas-page"].tap()
        XCTAssertTrue(app.buttons["inspect-canvas-image"].waitForExistence(timeout: 8))
        app.buttons["inspect-canvas-image"].tap()
        XCTAssertTrue(app.images["canvas-study-full-image"].waitForExistence(timeout: 8))
        app.buttons["close-source-image"].tap()
        let generate = app.buttons["request-source-flashcards"]
        app.swipeUp(); XCTAssertFalse(generate.isEnabled); app.swipeDown()
        app.buttons["recognize-canvas-study"].tap()
        app.swipeUp()
        let text = app.textViews["canvas-study-transcription"]
        let recognized = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "猫は"), object: text)
        XCTAssertEqual(XCTWaiter.wait(for: [recognized], timeout: 8), .completed)
        app.swipeUp(); XCTAssertFalse(generate.isEnabled)
        correctCanvasTranscription(app, text: text)
        app.buttons["confirm-canvas-transcription"].tap()
        generate.tap()
        XCTAssertTrue(app.staticTexts["source-quote-0"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["source-quote-0"].label.contains("Подтверждённая расшифровка"))
        text.tap(); text.typeText(" ")
        XCTAssertFalse(app.buttons["save-generated-flashcards"].exists)
        app.buttons["confirm-canvas-transcription"].tap(); generate.tap()
        XCTAssertTrue(app.staticTexts["source-quote-0"].waitForExistence(timeout: 8))
        app.buttons["save-generated-flashcards"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["save-generated-flashcards"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed)
        if !app.buttons["open-flashcards"].exists { app.buttons["BackButton"].tap() }
        try openStudyLibrary(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "flashcard-row-", "猫")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap(); app.swipeUp()
        XCTAssertTrue(app.staticTexts["Подтверждённая расшифровка"].waitForExistence(timeout: 8))
    }
    func testCanvasSelectedRegionRequiresConfirmationAndPreservesAsk() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--canvas-study-fixture"]; app.launch()
        try openTestNotebook(app)
        app.buttons["prepare-canvas-study"].tap(); app.buttons["prepare-canvas-region"].tap()
        let canvas = app.scrollViews["pencil-canvas"]
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.25))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.50))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(app.buttons["inspect-canvas-image"].waitForExistence(timeout: 8))
        app.swipeUp(); XCTAssertFalse(app.buttons["request-source-flashcards"].isEnabled); app.swipeDown()
        app.buttons["recognize-canvas-study"].tap()
        app.swipeUp()
        let text = app.textViews["canvas-study-transcription"]
        let recognized = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "猫は"), object: text)
        XCTAssertEqual(XCTWaiter.wait(for: [recognized], timeout: 8), .completed)
        correctCanvasTranscription(app, text: text)
        app.buttons["confirm-canvas-transcription"].tap(); app.buttons["request-source-flashcards"].tap()
        XCTAssertTrue(app.staticTexts["source-quote-0"].waitForExistence(timeout: 8))
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Закрыть", "Close"])).firstMatch.tap()
        app.buttons["select-region"].tap()
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(app.buttons["close-agent"].waitForExistence(timeout: 8))
    }

    func testAgentPromptKeepsKeyboardAboveCanvasAndCanSubmit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        try openTestNotebook(app)
        app.buttons["open-agent"].tap()
        let prompt = app.descendants(matching: .any)["agent-prompt"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        prompt.tap()
        prompt.typeText("Explain ")
        prompt.typeText("this note")
        XCTAssertEqual(prompt.value as? String, "Explain this note")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let send = app.buttons.matching(NSPredicate(format: "label IN %@", ["Отправить", "Send"])).firstMatch
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.staticTexts["Explain this note"].waitForExistence(timeout: 8))
        app.buttons["close-agent"].tap()
        XCTAssertTrue(app.scrollViews["pencil-canvas"].isHittable)
        app.buttons["open-agent"].tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        prompt.tap()
        prompt.typeText("Second question")
        XCTAssertEqual(prompt.value as? String, "Second question")
    }
    func testCanvasSizeAnalysisPreparesCopiesBeforeExplicitCompaction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--canvas-maintenance-fixture"]
        app.launch()
        let note = app.buttons["Практика"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10)); note.press(forDuration: 1)
        let analysis = app.buttons["analyze-canvas-日本語/Практика.studycanvas"]
        XCTAssertTrue(analysis.waitForExistence(timeout: 5)); analysis.tap()
        let prepare = app.buttons["prepare-canvas-copies"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["apply-canvas-compaction"].exists)
        prepare.tap()
        let apply = app.buttons["apply-canvas-compaction"]
        XCTAssertTrue(apply.waitForExistence(timeout: 15))
        let preview = XCTAttachment(screenshot: app.screenshot()); preview.name = "Canvas compaction prepared copies"; preview.lifetime = .keepAlways; add(preview)
        apply.tap()
        XCTAssertTrue(app.descendants(matching: .any)["canvas-compaction-complete"].waitForExistence(timeout: 15))
    }
    func testShareCardPreviewAndSystemSheetFromEditorAndPractice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        try openStudyLibrary(app)
        try addTextCard(app, word: "猫", translation: "кошка")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "flashcard-row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
        app.buttons["share-flashcard"].tap()
        XCTAssertTrue(app.images["flashcard-share-preview"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["share-flashcard-text"].exists)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Word card share preview"; preview.lifetime = .keepAlways; add(preview)
        try app.screenshot().pngRepresentation.write(to: URL.temporaryDirectory.appendingPathComponent("yohaku-share-preview.png"))
        app.buttons["share-flashcard-image"].tap()
        let systemShare = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(systemShare.waitForExistence(timeout: 8))
        let systemSheet = XCTAttachment(screenshot: app.screenshot())
        systemSheet.name = "Word card system share sheet"; systemSheet.lifetime = .keepAlways; add(systemSheet)
        try app.screenshot().pngRepresentation.write(to: URL.temporaryDirectory.appendingPathComponent("yohaku-share-system.png"))
        dismissSystemShare(app, sheet: systemShare)
        app.buttons["close-flashcard-share"].tap()
        app.buttons["cancel-flashcard-editor"].tap()
        app.buttons["study-flashcards"].tap()
        XCTAssertTrue(app.buttons["reveal-flashcard"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["share-study-flashcard"].exists)
        app.buttons["reveal-flashcard"].tap()
        app.buttons["share-study-flashcard"].tap()
        XCTAssertTrue(app.images["flashcard-share-preview"].waitForExistence(timeout: 8))
        app.buttons["share-flashcard-text"].tap()
        XCTAssertTrue(systemShare.waitForExistence(timeout: 8))
        dismissSystemShare(app, sheet: systemShare)
        app.buttons["close-flashcard-share"].tap()
        XCTAssertTrue(app.buttons["rate-flashcard-Помню"].exists)
        app.buttons["rate-flashcard-Помню"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["study-complete"].waitForExistence(timeout: 8))
    }

    private func dismissSystemShare(_ app: XCUIApplication, sheet: XCUIElement) {
        // iOS 26 presents the activity menu as a popover, without its own Close button.
        app.otherElements["PopoverDismissRegion"].firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed)
    }

    func testSwipeRatingsAndSecondRoundOfMistakes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        try openStudyLibrary(app)
        try addTextCard(app, word: "猫", translation: "кошка")
        try addTextCard(app, word: "犬", translation: "собака")
        try addTextCard(app, word: "鳥", translation: "птица")
        app.buttons["study-flashcards"].tap()
        let prompt = app.descendants(matching: .any).matching(identifier: "study-prompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        let mistakenWord = prompt.label
        // Swiping a hidden answer must not submit a rating.
        swipeStudyCard(app, dx: -0.38, dy: 0)
        XCTAssertTrue(app.buttons["reveal-flashcard"].exists)
        app.buttons["reveal-flashcard"].tap()
        swipeStudyCard(app, dx: -0.38, dy: 0)
        XCTAssertTrue(app.buttons["reveal-flashcard"].waitForExistence(timeout: 8))
        app.buttons["reveal-flashcard"].tap()
        swipeStudyCard(app, dx: 0, dy: -0.22)
        XCTAssertTrue(app.buttons["reveal-flashcard"].waitForExistence(timeout: 8))
        app.buttons["reveal-flashcard"].tap()
        swipeStudyCard(app, dx: 0.38, dy: 0)
        XCTAssertTrue(app.buttons["reveal-flashcard"].waitForExistence(timeout: 8))
        XCTAssertEqual(prompt.label, mistakenWord)
        XCTAssertTrue(app.staticTexts["study-round"].label.contains("круг 2"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Swipe cards - second round"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["reveal-flashcard"].tap()
        swipeStudyCard(app, dx: -0.38, dy: 0)
        let repeatMistakes = app.buttons["study-repeat-mistakes"]
        XCTAssertTrue(repeatMistakes.waitForExistence(timeout: 8))
        repeatMistakes.tap()
        XCTAssertTrue(app.buttons["reveal-flashcard"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["study-round"].label.contains("круг 3"))
        app.buttons["reveal-flashcard"].tap()
        swipeStudyCard(app, dx: 0.38, dy: 0)
        XCTAssertTrue(app.descendants(matching: .any)["study-complete"].waitForExistence(timeout: 8))
        XCTAssertFalse(repeatMistakes.exists)
    }

    func testQuizIncorrectChoiceReturnsInSecondRound() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        try openStudyLibrary(app)
        let translations = ["猫": "кошка", "犬": "собака", "鳥": "птица"]
        for word in translations.keys.sorted() { try addTextCard(app, word: word, translation: translations[word]!) }
        app.segmentedControls["study-practice-mode"].buttons.element(boundBy: 1).tap()
        app.buttons["study-flashcards"].tap()
        let prompt = app.descendants(matching: .any).matching(identifier: "study-prompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        let mistakenWord = prompt.label
        let correct = try XCTUnwrap(translations[mistakenWord])
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quiz-choice-"))
        XCTAssertEqual(choices.count, 3)
        let wrong = try XCTUnwrap(choices.allElementsBoundByIndex.first { $0.label != correct })
        wrong.tap()
        XCTAssertTrue(app.descendants(matching: .any)["study-answer-incorrect"].waitForExistence(timeout: 5))
        XCTAssertFalse(wrong.isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Quiz - incorrect choice"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["quiz-next"].tap()
        for _ in 0..<2 {
            waitForQuizChoices(choices)
            XCTAssertTrue(prompt.waitForExistence(timeout: 8))
            let answer = try XCTUnwrap(translations[prompt.label])
            let button = try XCTUnwrap(choices.allElementsBoundByIndex.first { $0.label == answer })
            button.tap()
            app.buttons["quiz-next"].tap()
        }
        waitForQuizChoices(choices)
        XCTAssertEqual(prompt.label, mistakenWord)
        XCTAssertTrue(app.staticTexts["study-round"].label.contains("круг 2"))
        let answer = try XCTUnwrap(translations[prompt.label])
        try XCTUnwrap(choices.allElementsBoundByIndex.first { $0.label == answer }).tap()
        app.buttons["quiz-next"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["study-complete"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["study-repeat-mistakes"].exists)
    }

    func testWordSearchFiltersCardsAndClearsResults() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        try openStudyLibrary(app)
        try addTextCard(app, word: "猫", translation: "кошка")
        try addTextCard(app, word: "犬", translation: "собака")
        let search = app.textFields["flashcards-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "flashcard-row-"))
        search.tap()
        search.typeText("КОШКА")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.label.contains("猫"))
        app.buttons["clear-flashcards-search"].tap()
        search.tap()
        search.typeText("犬")
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.label.contains("собака"))
        app.buttons["clear-flashcards-search"].tap()
        search.tap()
        search.typeText("неттакогослова")
        XCTAssertTrue(app.descendants(matching: .any)["flashcards-search-empty"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 0)
        app.buttons["clear-flashcards-search"].tap()
        XCTAssertEqual(rows.count, 2)
    }

    private func openStudyLibrary(_ app: XCUIApplication) throws {
        let library = app.buttons["open-flashcards"]
        XCTAssertTrue(library.waitForExistence(timeout: 15)); library.tap()
        XCTAssertTrue(app.buttons["add-flashcard"].waitForExistence(timeout: 8))
    }

    private func waitForQuizChoices(_ choices: XCUIElementQuery) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: choices.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
    }

    private func addTextCard(_ app: XCUIApplication, word: String, translation: String) throws {
        app.buttons["add-flashcard"].tap()
        let inputMode = app.segmentedControls["flashcard-input-mode"]
        XCTAssertTrue(inputMode.waitForExistence(timeout: 8))
        inputMode.buttons.element(boundBy: 1).tap()
        let japanese = app.textFields["flashcard-japanese"]
        XCTAssertTrue(japanese.waitForExistence(timeout: 8)); japanese.tap(); japanese.typeText(word)
        let meaning = app.textFields["flashcard-translation"]
        XCTAssertTrue(meaning.waitForExistence(timeout: 8)); meaning.tap(); meaning.typeText(translation)
        app.buttons["save-flashcard"].tap()
        XCTAssertTrue(app.buttons["add-flashcard"].waitForExistence(timeout: 8))
    }

    private func swipeStudyCard(_ app: XCUIApplication, dx: CGFloat, dy: CGFloat) {
        let face = app.descendants(matching: .any).matching(identifier: "study-prompt").firstMatch
        XCTAssertTrue(face.waitForExistence(timeout: 8))
        let start = face.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(
            dx: (face.frame.midX / app.frame.width) + dx,
            dy: face.frame.midY / app.frame.height + dy))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    func testHandwrittenVocabularyCardCanBeEditedAndStudied() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let library = app.buttons["open-flashcards"]
        XCTAssertTrue(library.waitForExistence(timeout: 15)); library.tap()
        let addCard = app.buttons["add-flashcard"]
        XCTAssertTrue(addCard.waitForExistence(timeout: 8)); addCard.tap()
        let save = app.buttons["save-flashcard"]
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        XCTAssertFalse(save.isEnabled)

        drawStroke(in: app, field: "flashcard-ink-japanese")
        XCTAssertFalse(save.isEnabled)
        drawStroke(in: app, field: "flashcard-ink-reading")
        drawStroke(in: app, field: "flashcard-ink-translation")
        XCTAssertTrue(save.isEnabled)
        let creation = XCTAttachment(screenshot: app.screenshot())
        creation.name = "Handwritten vocabulary card"; creation.lifetime = .keepAlways; self.add(creation)
        save.tap()

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "flashcard-row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
        let clearWord = app.buttons["flashcard-ink-japanese-clear"]
        XCTAssertTrue(clearWord.waitForExistence(timeout: 8))
        XCTAssertTrue(clearWord.isEnabled)
        clearWord.tap()
        XCTAssertFalse(save.isEnabled)
        drawStroke(in: app, field: "flashcard-ink-japanese")
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let study = app.buttons["study-flashcards"]
        XCTAssertTrue(study.waitForExistence(timeout: 8)); study.tap()
        XCTAssertTrue(app.descendants(matching: .any)["study-prompt"].waitForExistence(timeout: 8))
        let reveal = app.buttons["reveal-flashcard"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 8)); reveal.tap()
        let remember = app.buttons["rate-flashcard-Помню"]
        XCTAssertTrue(remember.waitForExistence(timeout: 8))
        let practice = XCTAttachment(screenshot: app.screenshot())
        practice.name = "Handwritten card in practice"; practice.lifetime = .keepAlways; self.add(practice)
        remember.tap()
        XCTAssertFalse(reveal.exists)
    }

    func testNativePencilPaletteFollowsFieldsAndHidesForKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let library = app.buttons["open-flashcards"]
        XCTAssertTrue(library.waitForExistence(timeout: 15)); library.tap()
        let add = app.buttons["add-flashcard"]
        XCTAssertTrue(add.waitForExistence(timeout: 8)); add.tap()
        XCTAssertTrue(app.descendants(matching: .any)["flashcard-paper-pattern"].waitForExistence(timeout: 8))
        let wordTools = app.buttons["flashcard-ink-japanese-tools"]
        XCTAssertTrue(wordTools.waitForExistence(timeout: 8)); wordTools.tap()
        let pencil = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Pencil")).firstMatch
        XCTAssertTrue(pencil.waitForExistence(timeout: 8), app.debugDescription)
        pencil.tap()
        // Tapping an already selected native tool opens its settings popover.
        // Dismiss that popover outside the drawing fields before drawing.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.32)).tap()
        drawStroke(in: app, field: "flashcard-ink-japanese")
        XCTAssertTrue(app.buttons["flashcard-ink-japanese-clear"].isEnabled)

        let readingTools = app.buttons["flashcard-ink-reading-tools"]
        XCTAssertTrue(readingTools.exists); readingTools.tap()
        XCTAssertTrue(pencil.waitForExistence(timeout: 5))
        drawStroke(in: app, field: "flashcard-ink-reading")
        XCTAssertTrue(app.buttons["flashcard-ink-reading-clear"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Native PencilKit palette and Japanese grid"
        attachment.lifetime = .keepAlways
        self.add(attachment)

        app.buttons["flashcard-ink-reading-tools"].tap()
        XCTAssertFalse(pencil.waitForExistence(timeout: 2))
        // Open again, then change input mode: the native palette must disappear.
        app.buttons["flashcard-ink-japanese-tools"].tap()
        XCTAssertTrue(pencil.waitForExistence(timeout: 5))
        let mode = app.segmentedControls["flashcard-input-mode"]
        mode.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.textFields["flashcard-japanese"].waitForExistence(timeout: 5))
        XCTAssertFalse(pencil.exists)
    }

    private func drawStroke(in app: XCUIApplication, field identifier: String) {
        let field = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        // A partially visible canvas can still be hittable while the stroke ends
        // outside the form. Scroll at the margin, away from ink and the palette.
        let paletteVisible = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Pencil")).firstMatch.exists
        let visibleBottom = app.frame.maxY - (paletteVisible ? 160 : 60)
        for _ in 0..<4 {
            if field.frame.minY >= app.frame.minY + 160 && field.frame.maxY <= visibleBottom { break }
            let scrollUp = field.frame.maxY > visibleBottom
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: scrollUp ? 0.78 : 0.4))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: scrollUp ? 0.4 : 0.78))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
        let end = field.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

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
        try openTestNotebook(app)
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
