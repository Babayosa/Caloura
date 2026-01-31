import XCTest
@testable import SnapNote

final class ContextDetectorTests: XCTestCase {

    func testCategorize_vsCode() {
        let category = ContextDetector.categorize(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            windowTitle: "main.swift - SnapNote"
        )
        XCTAssertEqual(category, .code)
    }

    func testCategorize_xcode() {
        let category = ContextDetector.categorize(
            bundleID: "com.apple.dt.Xcode",
            appName: "Xcode",
            windowTitle: "SnapNote.xcodeproj"
        )
        XCTAssertEqual(category, .code)
    }

    func testCategorize_zoomLecture() {
        let category = ContextDetector.categorize(
            bundleID: "us.zoom.xos",
            appName: "zoom.us",
            windowTitle: "CS 101 Lecture"
        )
        XCTAssertEqual(category, .lecture)
    }

    func testCategorize_browserWithCanvas() {
        let category = ContextDetector.categorize(
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Dashboard - Canvas"
        )
        XCTAssertEqual(category, .lecture)
    }

    func testCategorize_browserGeneric() {
        let category = ContextDetector.categorize(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Apple"
        )
        XCTAssertEqual(category, .web)
    }

    func testCategorize_slack() {
        let category = ContextDetector.categorize(
            bundleID: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            windowTitle: "#general"
        )
        XCTAssertEqual(category, .chat)
    }

    func testCategorize_unknown() {
        let category = ContextDetector.categorize(
            bundleID: "com.unknown.app",
            appName: "SomeApp",
            windowTitle: "Window"
        )
        XCTAssertEqual(category, .other)
    }

    func testCategorize_terminalAsCode() {
        let category = ContextDetector.categorize(
            bundleID: "com.apple.Terminal",
            appName: "Terminal",
            windowTitle: "bash"
        )
        XCTAssertEqual(category, .code)
    }

    func testCategorize_browserWithMoodle() {
        let category = ContextDetector.categorize(
            bundleID: "org.mozilla.firefox",
            appName: "Firefox",
            windowTitle: "Moodle: CS 301 - Homework 5"
        )
        XCTAssertEqual(category, .lecture)
    }
}
