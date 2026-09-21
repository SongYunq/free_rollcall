import XCTest

final class AppFlowTests: XCTestCase {
    @MainActor func testModernSystemTabBarPreservesCourseNavigation() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("系统液态玻璃底栏仅用于 iOS 26 及以上") }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture"]
        app.launch()

        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "新系统必须使用原生标签栏")
        let home = bar.buttons["功能"]
        let logs = bar.buttons["本地日志"]
        let accounts = bar.buttons["账号管理"]
        XCTAssertEqual(bar.buttons.count, 3)
        for (button, title) in [(home, "功能"), (logs, "本地日志"), (accounts, "账号管理")] {
            XCTAssertTrue(button.isHittable)
            XCTAssertEqual(button.label, title)
        }
        XCTAssertLessThan(home.frame.midX, logs.frame.midX)
        XCTAssertLessThan(logs.frame.midX, accounts.frame.midX)
        XCTAssertTrue(home.isSelected)

        app.buttons["enter-courses"].tap()
        XCTAssertTrue(app.navigationBars["本学期课程"].waitForExistence(timeout: 5))
        logs.tap()
        XCTAssertTrue(app.navigationBars["本地日志"].waitForExistence(timeout: 3))
        XCTAssertTrue(logs.isSelected)
        accounts.tap()
        XCTAssertTrue(app.navigationBars["账号管理"].waitForExistence(timeout: 3))
        home.tap()
        XCTAssertTrue(app.navigationBars["本学期课程"].waitForExistence(timeout: 3), "切换页面后应保留课程路径")
        XCTAssertTrue(home.isSelected)
    }

    @MainActor func testLargeTextStillShowsAllFourAccountActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["账号管理"].waitForExistence(timeout: 10))
        app.buttons["账号管理"].tap()
        let account = app.staticTexts["常用账号"].firstMatch
        for _ in 0..<4 {
            if account.isHittable && account.frame.midY < app.frame.height * 0.65 { break }
            app.swipeUp()
        }
        XCTAssertTrue(account.exists)
        account.swipeLeft()
        for title in ["登录", "修改", "默认", "删除"] {
            let button = app.buttons[title]
            XCTAssertTrue(button.isHittable, title)
            XCTAssertLessThan(button.frame.maxY, app.buttons["账号管理"].frame.minY, "\(title) 应完整显示在底栏上方")
        }
    }
    @MainActor func testThreePagesLeftSwipeAndAttendanceFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["enter-courses"].waitForExistence(timeout: 10))
        app.buttons["账号管理"].tap()
        let row = app.otherElements["account-demo001"].firstMatch
        let account = row.exists ? row : app.staticTexts["常用账号"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        account.swipeLeft()
        XCTAssertTrue(app.buttons["登录"].exists)
        XCTAssertTrue(app.buttons["修改"].exists)
        XCTAssertTrue(app.buttons["默认"].exists)
        XCTAssertTrue(app.buttons["删除"].exists)
        app.buttons["修改"].tap()
        XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["username"].value as? String, "demo001")
        app.buttons["取消"].tap()
        app.buttons["功能"].tap()
        app.buttons["enter-courses"].tap()
        let course = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "软件工程与实践")).firstMatch
        XCTAssertTrue(course.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["本学期课程"].exists)
        XCTAssertFalse(app.buttons["加载更多课程"].exists)
        course.tap()
        let attendance = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "数字签到", "点击此条目签到")).firstMatch
        XCTAssertTrue(attendance.waitForExistence(timeout: 5))
        attendance.tap()
        XCTAssertTrue(app.staticTexts["签到成功"].waitForExistence(timeout: 5))
        app.buttons["本地日志"].tap()
        XCTAssertTrue(app.navigationBars["本地日志"].waitForExistence(timeout: 3))
    }
}
