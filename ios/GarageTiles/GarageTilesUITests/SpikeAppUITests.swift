import XCTest

/** Drives the Phase 0 app screen in the iOS Simulator; widget placement cannot be automated, so this covers the app and App Group only. */
@MainActor
final class SpikeAppUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        let tab = app.tabBars.buttons["Spike"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
    }

    private func value(_ identifier: String) -> String {
        let element = app.staticTexts[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(identifier)")
        return element.label
    }

    private func count(_ identifier: String) -> Int {
        let raw = value(identifier)
        guard let number = Int(raw) else {
            XCTFail("\(identifier) is \(raw), not a number")
            return -1
        }
        return number
    }

    func testAppGroupIsReadable() {
        launch()
        XCTAssertEqual(value("appGroupStatus"), "Readable")
        attachScreenshot(named: "App screen")
    }

    func testBumpingEachTileFromTheAppUpdatesOnlyThatTile() {
        launch()
        let total = count("totalValue")
        let alpha = count("tileValue-alpha")
        let bravo = count("tileValue-bravo")

        app.buttons["Bump Tile A from the app"].tap()
        XCTAssertEqual(count("totalValue"), total + 1)
        XCTAssertEqual(count("tileValue-alpha"), alpha + 1)
        XCTAssertEqual(count("tileValue-bravo"), bravo)
        XCTAssertEqual(value("lastTileValue"), "Tile A")
        XCTAssertTrue(value("lastWriterValue").hasPrefix("App ("), value("lastWriterValue"))

        app.buttons["Bump Tile B from the app"].tap()
        XCTAssertEqual(count("totalValue"), total + 2)
        XCTAssertEqual(count("tileValue-alpha"), alpha + 1)
        XCTAssertEqual(count("tileValue-bravo"), bravo + 1)
        XCTAssertEqual(value("lastTileValue"), "Tile B")
        attachScreenshot(named: "After bumping both tiles")
    }

    func testCounterSurvivesRelaunch() {
        launch()
        app.buttons["Bump Tile A from the app"].tap()
        let total = count("totalValue")
        app.terminate()
        launch()
        XCTAssertEqual(count("totalValue"), total)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
