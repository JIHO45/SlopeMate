//
//  SlopeMateUITests.swift
//  SlopeMateUITests
//
//  Created by 박지호 on 12/1/25.
//

import XCTest

final class SlopeMateUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testSeasonPassManagementFromRecordTab() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        let tabs = app.tabBars
        tabs.buttons["시즌"].tap()
        app.buttons["시즌권 관리"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["시즌권"].waitForExistence(timeout: 5))
        tabs.buttons["홈"].tap()
        XCTAssertTrue(tabs.buttons["홈"].isSelected)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
