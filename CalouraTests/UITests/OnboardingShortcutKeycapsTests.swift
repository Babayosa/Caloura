import XCTest
@testable import Caloura

@MainActor
final class OnboardingShortcutKeycapsTests: XCTestCase {

    func testModifierSymbols_becomeOneBadgeEach() {
        XCTAssertEqual(
            onboardingShortcutKeycaps(from: "\u{2303}\u{2325}C"),
            ["\u{2303}", "\u{2325}", "C"]
        )
    }

    func testMultiCharacterKeys_stayTogether() {
        XCTAssertEqual(onboardingShortcutKeycaps(from: "\u{2318}F19"), ["\u{2318}", "F19"])
    }

    func testPlusAndWhitespaceSeparators_areDropped() {
        XCTAssertEqual(onboardingShortcutKeycaps(from: "\u{2318} + \u{21E7} + 4"), ["\u{2318}", "\u{21E7}", "4"])
    }

    func testSymbolOnlyInput_fallsBackToWholeString() {
        XCTAssertEqual(onboardingShortcutKeycaps(from: " + "), [" + "])
    }

    func testPlainWord_isSingleKeycap() {
        XCTAssertEqual(onboardingShortcutKeycaps(from: "Space"), ["Space"])
    }
}
