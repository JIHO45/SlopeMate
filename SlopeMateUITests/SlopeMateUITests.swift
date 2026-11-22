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

    /// 첫 시즌권을 저장하면 시트가 닫히자마자 목록이 보여야 한다(빈 화면으로 남지 않음, R8)
    @MainActor
    func testFirstSeasonPassShowsRightAfterSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-SMDemo", "-SMDemoWeather", "-homeSetupDone", "YES"]  // 첫 실행 화면 건너뜀
        app.launch()
        app.tabBars.buttons["시즌"].tap()
        let manage = app.descendants(matching: .any)["시즌권 관리"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
        XCTAssertTrue(app.navigationBars["시즌권"].waitForExistence(timeout: 5))

        // 데모 DB에 남은 시즌권은 지워 빈 상태에서 시작
        let empty = app.staticTexts["시즌권 가격을 넣으면 1회 방문당 금액을 알려 드려요"]
        while !empty.waitForExistence(timeout: 2) {
            app.collectionViews.buttons.firstMatch.tap()
            app.buttons["시즌권 삭제"].tap()
            app.alerts.buttons["지우기"].tap()
            _ = app.navigationBars["시즌권 수정"].waitForNonExistence(timeout: 3)
        }

        app.buttons["시즌권 추가"].firstMatch.tap()
        let name = app.textFields["예: 하이원 시즌권"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap(); name.typeText("UITest pass")
        let price = app.textFields["가격"]
        price.tap(); price.typeText("500000")
        app.buttons["모나 용평"].tap()
        app.buttons["저장"].tap()

        XCTAssertTrue(app.navigationBars["시즌권 추가"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UITest pass")).firstMatch.waitForExistence(timeout: 1))
        XCTAssertFalse(empty.exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
