import XCTest

/** Drives the Doors tab without a myQ session; nothing here contacts myQ or moves a door. */
@MainActor
final class DoorsUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launchOnDoorsTab() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        let tab = app.tabBars.buttons["Doors"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
    }

    private func expandTokenImport() {
        let advanced = app.buttons["Advanced: import a token"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        advanced.tap()
    }

    func testDoorsTabOffersSignInWithTokenImportTuckedAway() {
        launchOnDoorsTab()
        let signIn = app.buttons["signInButton"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        XCTAssertEqual(signIn.label, "Sign in with myQ")
        XCTAssertTrue(signIn.isEnabled)
        XCTAssertFalse(app.secureTextFields["tokenField"].exists)
        expandTokenImport()
        XCTAssertTrue(app.secureTextFields["tokenField"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["importTokenButton"].isEnabled)
        XCTAssertEqual(app.staticTexts["sessionStatus"].label, "Not signed in")
        XCTAssertTrue(app.staticTexts["noDoorsMessage"].exists)
        XCTAssertTrue(app.staticTexts["lockedPhoneWarning"].exists)
        XCTAssertFalse(app.buttons["exportRequestLogButton"].exists, "there is no request log to export before any myQ request")
    }

    func testImportRejectsAnAuthorizationHeaderWithoutNetwork() {
        launchOnDoorsTab()
        expandTokenImport()
        let field = app.secureTextFields["tokenField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Bearer abcdefghijklmnopqrstuvwxyz0123456789")
        app.buttons["importTokenButton"].tap()
        let message = app.staticTexts["importMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "That looks like an Authorization header. Paste only the refresh token.")
        XCTAssertEqual(app.staticTexts["sessionStatus"].label, "Not signed in")
    }

    func testDoorsTabLinksToTheSiriPhrases() {
        launchOnDoorsTab()
        let shortcutsLink = app.descendants(matching: .any)["shortcutsLink"]
        for _ in 0..<4 where !shortcutsLink.exists { app.swipeUp() }
        XCTAssertTrue(shortcutsLink.exists, "the Shortcuts link shows every Siri phrase")
    }
}
