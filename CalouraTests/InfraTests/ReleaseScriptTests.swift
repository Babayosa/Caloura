import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Caloura

final class ReleaseScriptTests: XCTestCase {

    func testReleaseScriptUsesNeutralDmgBackgroundAsset() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let releaseScriptURL = repoRoot.appendingPathComponent("scripts/release.sh")
        let assetURL = repoRoot.appendingPathComponent("scripts/assets/dmg-neutral-background.png")
        let releaseScript = try String(contentsOf: releaseScriptURL, encoding: .utf8)
        let imageSource = CGImageSourceCreateWithURL(assetURL as CFURL, nil)
        let properties = imageSource
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }

        XCTAssertTrue(releaseScript.contains("scripts/assets/dmg-neutral-background.png"))
        XCTAssertFalse(releaseScript.contains("AppIcon.appiconset/icon_512x512.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
        XCTAssertEqual(properties?[kCGImagePropertyPixelWidth] as? Int, 1120)
        XCTAssertEqual(properties?[kCGImagePropertyPixelHeight] as? Int, 720)
    }
}
