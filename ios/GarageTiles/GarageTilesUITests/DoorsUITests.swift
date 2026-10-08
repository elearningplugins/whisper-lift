import XCTest

/** Drives the doors screen without a myQ session; nothing here contacts myQ or moves a door. */
@MainActor
final class DoorsUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch() {
        continueAfterFailure = false
        app = XCUIApplication()
        // Starts signed out on throwaway storage that can't reach myQ, so the tests never touch a real session or door.
        app.launchArguments.append("-WhisperLiftUITestSandbox")
        app.launch()
    }

    private func expandTokenImport() {
        let advanced = app.buttons["Advanced: import a token"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        advanced.tap()
    }

    func testSignedOutScreenOffersSignInWithTokenImportTuckedAway() {
        launch()
        let signIn = app.buttons["signInButton"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        XCTAssertEqual(signIn.label, "Sign in with myQ")
        XCTAssertTrue(signIn.isEnabled)
        XCTAssertFalse(app.secureTextFields["tokenField"].exists)
        expandTokenImport()
        XCTAssertTrue(app.secureTextFields["tokenField"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["importTokenButton"].isEnabled)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the app is one screen with no tab bar")
        XCTAssertFalse(app.buttons["exportRequestLogButton"].exists, "the header with Export JSON appears only when signed in")
        XCTAssertFalse(app.buttons["settingsButton"].exists)
    }

    func testImportRejectsAnAuthorizationHeaderWithoutNetwork() {
        launch()
        expandTokenImport()
        let field = app.secureTextFields["tokenField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Bearer abcdefghijklmnopqrstuvwxyz0123456789")
        app.buttons["importTokenButton"].tap()
        let message = app.staticTexts["importMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "That looks like an Authorization header. Paste only the refresh token.")
        XCTAssertTrue(app.buttons["signInButton"].exists, "still signed out")
    }
}
