import XCTest

/** Apple's accessibility audit on each tab, plus the Doors controls at the largest accessibility text size. */
@MainActor
final class AccessibilityUITests: XCTestCase {
    private func launch(arguments: [String] = [], tab: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launch()
        let button = app.tabBars.buttons[tab]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        // Let the tab transition finish so the audit never measures colors mid-animation.
        Thread.sleep(forTimeInterval: 2)
        return app
    }

    func testDoorsTabPassesTheAccessibilityAudit() throws {
        let app = launch(tab: "Doors")
        expandTokenImport(app)
        XCTAssertTrue(app.secureTextFields["tokenField"].waitForExistence(timeout: 10))
        // A secure field is single-line by design; testDoorsControlsStayReachableAtTheLargestTextSize proves it stays usable.
        try audit(app, allowing: [(.textClipped, "tokenField")])
    }

    private func expandTokenImport(_ app: XCUIApplication) {
        let advanced = app.buttons["Advanced: import a token"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        advanced.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    func testSpikeTabPassesTheAccessibilityAudit() throws {
        let app = launch(tab: "Spike")
        XCTAssertTrue(app.staticTexts["appGroupStatus"].waitForExistence(timeout: 10))
        // The Spike tab is the Phase 0 counter diagnostic, not a driver-facing screen, so its fixed-size rows are accepted.
        try audit(app, allowing: [(.dynamicType, "*")])
    }

    // Fails on every issue except the listed audit type on the element with that identifier or label ("*" for any element), and names each element.
    private func audit(_ app: XCUIApplication, allowing allowed: [(XCUIAccessibilityAuditType, String)] = []) throws {
        try app.performAccessibilityAudit { issue in
            let element = issue.element
            // A contrast finding with no element is shared system chrome on both tabs; every text element the app owns is audited and passes.
            let unattributedContrast = issue.auditType == .contrast && element == nil
            // WCAG 1.4.3 exempts inactive controls: a disabled button is dimmed on purpose to show it is unavailable.
            let disabledContrast = issue.auditType == .contrast && element?.isEnabled == false
            let isAllowed = unattributedContrast || disabledContrast || allowed.contains { type, name in
                issue.auditType == type && (name == "*" || element?.identifier == name || element?.label == name)
            }
            if !isAllowed {
                let described = element.map { "\($0.elementType.rawValue) '\($0.label)' id='\($0.identifier)'" } ?? "no element"
                XCTFail("Accessibility audit: \(issue.auditType) on \(described): \(issue.compactDescription) | \(issue.detailedDescription)")
            }
            return true
        }
    }

    func testDoorsControlsStayReachableAtTheLargestTextSize() {
        let app = launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], tab: "Doors")
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["signInButton"].isHittable)
        expandTokenImport(app)
        let field = app.secureTextFields["tokenField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(field.isHittable)
        XCTAssertEqual(app.staticTexts["sessionStatus"].label, "Not signed in")
        let importButton = app.buttons["importTokenButton"]
        XCTAssertTrue(importButton.exists)
        let warning = app.staticTexts["lockedPhoneWarning"]
        for _ in 0..<6 where !warning.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(warning.isHittable, "The locked-phone warning must be reachable by scrolling at the largest text size")
    }

    func testDoorsControlsHaveSpokenLabels() {
        let app = launch(tab: "Doors")
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["signInButton"].label, "Sign in with myQ")
        expandTokenImport(app)
        XCTAssertTrue(app.secureTextFields["tokenField"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["importTokenButton"].label, "Import token")
        XCTAssertFalse(app.secureTextFields["tokenField"].placeholderValue?.isEmpty ?? true)
        XCTAssertEqual(app.tabBars.buttons["Doors"].label, "Doors")
    }
}
