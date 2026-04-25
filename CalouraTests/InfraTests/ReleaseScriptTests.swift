import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Caloura

final class ReleaseScriptTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testReleaseScriptUsesNeutralDmgBackgroundAsset() throws {
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

    func testReleaseScriptGuardOnlyRunsBeforeEnvironmentVerification() throws {
        let releaseScript = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/release.sh"),
            encoding: .utf8
        )
        let guardRange = try XCTUnwrap(
            releaseScript.range(of: "if [ \"${RELEASE_GUARD_ONLY:-0}\" = \"1\" ]")
        )
        let searchRange = guardRange.upperBound..<releaseScript.endIndex
        let environmentRange = try XCTUnwrap(
            releaseScript.range(of: "verify_release_environment", range: searchRange)
        )

        XCTAssertLessThan(guardRange.lowerBound, environmentRange.lowerBound)
    }

    func testReleaseScriptUsesStableBuildMetadata() throws {
        let releaseScript = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/release.sh"),
            encoding: .utf8
        )

        XCTAssertFalse(releaseScript.contains("BUILD_TIMESTAMP"))
        XCTAssertTrue(releaseScript.contains("release_build_number()"))
        XCTAssertTrue(
            releaseScript.contains("BUILD_NUMBER=\"$(release_build_number \"$(normalize_version \"$VERSION\")\")\"")
        )
        XCTAssertFalse(releaseScript.contains("BUILD_NUMBER=\"$(build_setting_value \"CURRENT_PROJECT_VERSION\")\""))
        XCTAssertTrue(releaseScript.contains("100_000_000_000_000"))
        XCTAssertTrue(releaseScript.contains("timestamp-style build numbers"))
        XCTAssertTrue(releaseScript.contains("CURRENT_PROJECT_VERSION=\"$BUILD_NUMBER\""))
        XCTAssertTrue(releaseScript.contains("$APP_NAME-$VERSION.zip"))
    }

    func testReleaseReadinessAndCoverageGatesDoNotReferenceRemovedScrollCaptureFiles() throws {
        let releaseReady = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/release_ready.sh"),
            encoding: .utf8
        )
        let coverageGate = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/coverage_gate.py"),
            encoding: .utf8
        )

        XCTAssertFalse(releaseReady.contains("ScrollCaptureEngineTests"))
        XCTAssertFalse(coverageGate.contains("ScrollCaptureEngine.swift"))
        XCTAssertFalse(coverageGate.contains("CapturePipeline+EntryPoints.swift"))
        XCTAssertTrue(releaseReady.contains("CapturePipelineEntryPointTests"))
        XCTAssertTrue(coverageGate.contains("CaptureEntrypointService.swift"))
    }
}
