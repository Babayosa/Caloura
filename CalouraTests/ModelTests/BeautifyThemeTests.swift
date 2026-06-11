import XCTest
@testable import Caloura

final class BeautifyThemeTests: XCTestCase {

    func testBuiltInThemes_haveStablePinnedIDs() {
        let expected: [String: String] = [
            "Clean": "00000000-0000-0000-0000-000000000001",
            "Ocean": "00000000-0000-0000-0000-000000000002",
            "Sunset": "00000000-0000-0000-0000-000000000003",
            "Midnight": "00000000-0000-0000-0000-000000000004",
            "Neon": "00000000-0000-0000-0000-000000000005"
        ]
        XCTAssertEqual(BeautifyTheme.builtInThemes.count, expected.count)
        for theme in BeautifyTheme.builtInThemes {
            XCTAssertEqual(
                theme.id,
                UUID(uuidString: expected[theme.name] ?? ""),
                "theme \(theme.name) must keep its pinned built-in UUID"
            )
        }
    }

    func testBuiltInThemes_idsAreUnique() {
        let ids = Set(BeautifyTheme.builtInThemes.map(\.id))
        XCTAssertEqual(ids.count, BeautifyTheme.builtInThemes.count)
    }

    func testThemeNamed_findsBuiltInsAndRejectsUnknown() {
        XCTAssertEqual(BeautifyTheme.theme(named: "Ocean")?.name, "Ocean")
        XCTAssertNil(BeautifyTheme.theme(named: "NotATheme"))
    }
}
