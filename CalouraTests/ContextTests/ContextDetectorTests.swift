import XCTest
@testable import Caloura

final class ContextDetectorTests: XCTestCase {

    func testCategorize_vsCode() {
        let category = ContextDetector.categorize(bundleID: "com.microsoft.VSCode")
        XCTAssertEqual(category, .code)
    }

    func testCategorize_xcode() {
        let category = ContextDetector.categorize(bundleID: "com.apple.dt.Xcode")
        XCTAssertEqual(category, .code)
    }

    func testCategorize_zoom() {
        let category = ContextDetector.categorize(bundleID: "us.zoom.xos")
        XCTAssertEqual(category, .lecture)
    }

    func testCategorize_chrome() {
        let category = ContextDetector.categorize(bundleID: "com.google.Chrome")
        XCTAssertEqual(category, .web)
    }

    func testCategorize_safari() {
        let category = ContextDetector.categorize(bundleID: "com.apple.Safari")
        XCTAssertEqual(category, .web)
    }

    func testCategorize_slack() {
        let category = ContextDetector.categorize(bundleID: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(category, .chat)
    }

    func testCategorize_unknown() {
        let category = ContextDetector.categorize(bundleID: "com.unknown.app")
        XCTAssertEqual(category, .other)
    }

    func testCategorize_terminal() {
        let category = ContextDetector.categorize(bundleID: "com.apple.Terminal")
        XCTAssertEqual(category, .code)
    }

    func testCategorize_firefox() {
        let category = ContextDetector.categorize(bundleID: "org.mozilla.firefox")
        XCTAssertEqual(category, .web)
    }
}
