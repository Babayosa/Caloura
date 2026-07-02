import XCTest
import AppKit
@testable import Caloura

/// Exercises the native share flow one level deeper than `CaptureShareItemsTests`:
/// it feeds the items the app actually resolves into the *real* `NSSharingServicePicker`
/// API used at `QuickAccessOverlay.presentSharePicker`, then confirms the picker builds an
/// enabled, titled share menu item over that payload. `CaptureShareItemsTests` asserts only
/// the resolved-item *shape*; this asserts the items are an actionable share payload — the
/// picker's initializer traps on an empty/invalid payload, so a clean construction plus an
/// enabled `standardShareMenuItem` is the presentation-level proof. Everything here is
/// deterministic and headless-safe (no windowserver session or deprecated API).
@MainActor
final class CaptureSharePickerPresentationTests: XCTestCase {

    /// Writes a genuine PNG so a file-URL payload points at a real on-disk file (not a
    /// missing path). Built via `NSBitmapImageRep` directly — no `lockFocus` graphics
    /// context — so it works in a headless test process. Pixel content is irrelevant.
    private func writeTemporaryPNG() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("caloura-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("shot.png")

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let png = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("PNG encoding unavailable in this environment")
        }
        try png.write(to: url)
        return url
    }

    /// Asserts the resolved items are a presentable share payload by driving them through
    /// the exact `NSSharingServicePicker` initializer the app calls. That initializer traps
    /// on an empty/invalid payload, so reaching the assertions already proves shareability;
    /// the enabled, titled `standardShareMenuItem` proves the picker built a usable share
    /// representation. Deterministic and session-independent (verified headless).
    private func assertShareable(_ items: [Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(items.isEmpty, "resolved share items must be non-empty", file: file, line: line)
        let picker = NSSharingServicePicker(items: items)
        let menuItem = picker.standardShareMenuItem
        XCTAssertFalse(
            menuItem.title.isEmpty,
            "the picker must produce a titled share menu item", file: file, line: line)
        XCTAssertTrue(
            menuItem.isEnabled,
            "the share menu item must be enabled for a valid payload", file: file, line: line)
    }

    // MARK: - File-URL branch (saved capture + history)

    func testSavedScreenshotResolvesFileURLAndPresents() throws {
        let url = try writeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let screenshot = CapturePipelineTestHelpers.makeProcessed()
        screenshot.filePath = url
        let items = CaptureShareItems.items(for: screenshot)

        XCTAssertEqual(items.first as? URL, url, "a saved capture must share the on-disk file URL")
        assertShareable(items)
    }

    func testHistoryItemResolvesFileURLAndPresents() throws {
        let url = try writeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let item = ScreenshotItem(
            filePath: url.path, fileName: "shot.png",
            sourceAppName: nil, sourceWindowTitle: nil,
            captureMode: "area", width: 24, height: 24)
        let items = CaptureShareItems.items(for: item)

        XCTAssertEqual(items.first as? URL, url, "a history item must share its on-disk file URL")
        assertShareable(items)
    }

    // MARK: - NSImage branch (unsaved capture)

    func testUnsavedScreenshotResolvesImageAndPresents() {
        let screenshot = CapturePipelineTestHelpers.makeProcessed()
        XCTAssertNil(screenshot.filePath, "fixture capture starts unsaved")
        let items = CaptureShareItems.items(for: screenshot)

        XCTAssertTrue(items.first is NSImage, "an unsaved capture must fall back to the in-memory image")
        assertShareable(items)
    }
}
