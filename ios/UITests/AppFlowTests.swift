import XCTest

final class AppFlowTests: XCTestCase {
    @MainActor func testHistoryCountsKeepAnsweredAndAbsentRowsDistinct() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["enter-courses"].waitForExistence(timeout: 10))
        app.buttons["enter-courses"].tap()
        let course = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "软件工程与实践")).firstMatch
        XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap()
        for (id, status, count) in [("701", "正在签到", "2/4"), ("702", "正在签到", "1/4"),
                                    ("703", "已签到", "4/4"), ("704", "缺勤", "1/4")] {
            let row = app.buttons["attendance-\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            for _ in 0..<4 {
                if row.isHittable { break }
                app.swipeUp()
            }
            let codeOrKind = id == "702" ? "雷达签到" : "签到码  0123"
            let loaded = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@", codeOrKind, status, count)
            expectation(for: loaded, evaluatedWith: row)
            waitForExpectations(timeout: 5)
            let counts = row.staticTexts["attendance-counts-\(id)"]
            XCTAssertEqual(counts.label, count)
            XCTAssertGreaterThan(counts.frame.minX, row.frame.midX, "人数应位于条目右侧")
            XCTAssertLessThanOrEqual(counts.frame.maxX, row.frame.maxX, "人数应完整显示在条目内")
            XCTAssertTrue(row.label.contains("已签到/总人数"))
            if id != "704" { XCTAssertFalse(row.label.contains("缺勤")) }
            XCTAssertFalse(app.navigationBars["签到详情"].exists)
            if id == "703" {
                row.tap()
                XCTAssertTrue(app.navigationBars["签到详情"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["已签到"].waitForExistence(timeout: 5))
                let detailCounts = app.descendants(matching: .any)["attendance-detail-counts"].firstMatch
                XCTAssertTrue(detailCounts.waitForExistence(timeout: 5))
                XCTAssertTrue(detailCounts.label.contains("签到人数"))
                XCTAssertTrue(detailCounts.label.contains("4/4"))
                app.buttons["完成"].tap()
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                expectation(for: NSPredicate(format: "label CONTAINS %@", "已签到"), evaluatedWith: row)
                waitForExpectations(timeout: 5)
                XCTAssertFalse(row.label.contains("已结束"))
                XCTAssertFalse(row.label.contains("缺勤"))
            }
        }
    }

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

    @MainActor func testLargeTextKeepsAccountActionsAndAttendanceCountsReadable() throws {
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
        app.buttons["功能"].tap()
        app.buttons["enter-courses"].tap()
        let course = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "软件工程与实践")).firstMatch
        XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap()
        let attendance = app.buttons["attendance-701"]
        XCTAssertTrue(attendance.waitForExistence(timeout: 5))
        let counts = attendance.staticTexts["attendance-counts-701"]
        for _ in 0..<5 {
            if counts.isHittable { break }
            app.swipeUp()
        }
        expectation(for: NSPredicate(format: "label == %@", "2/4"), evaluatedWith: counts)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(counts.isHittable)
        XCTAssertGreaterThan(counts.frame.minX, attendance.frame.midX)
        XCTAssertLessThanOrEqual(counts.frame.maxX, app.frame.maxX - 12)
        XCTAssertTrue(attendance.label.contains("正在签到"))
        XCTAssertTrue(attendance.label.contains("已签到/总人数"))
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
        expectation(for: NSPredicate(format: "label CONTAINS %@", "2/4"), evaluatedWith: attendance)
        waitForExpectations(timeout: 5)
        attendance.tap()
        XCTAssertTrue(app.staticTexts["签到成功"].waitForExistence(timeout: 5))
        let submitted = app.buttons["attendance-701"]
        expectation(for: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "已签到", "3/4"), evaluatedWith: submitted)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(submitted.label.contains("点击此条目签到"))
        app.buttons["本地日志"].tap()
        XCTAssertTrue(app.navigationBars["本地日志"].waitForExistence(timeout: 3))
    }
}
