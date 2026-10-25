import XCTest

extension XCUIApplication {
    /// Existing document/library tests begin from the menu; production starts on Today.
    @MainActor func launchAtWorkspaceMenu() {
        launch()
        let menu = buttons["open-workspace-menu"]
        if menu.waitForExistence(timeout: 15), menu.isHittable, !buttons["open-today"].isHittable { menu.tap() }
    }
}
