import XCTest
@testable import SnapNote

final class FileOrganizerTests: XCTestCase {

    func testGenerateFileName_withAppName() {
        let context = CaptureContext(
            mode: .area,
            sourceAppName: "Safari",
            sourceWindowTitle: "Apple",
            timestamp: makeDate(hour: 14, minute: 30, second: 45)
        )

        let screenshot = makeProcessedScreenshot(context: context)
        let fileName = FileOrganizer.generateFileName(for: screenshot)

        XCTAssertEqual(fileName, "SnapNote_14-30-45_Safari.png")
    }

    func testGenerateFileName_withoutAppName() {
        let context = CaptureContext(
            mode: .fullscreen,
            sourceAppName: nil,
            timestamp: makeDate(hour: 9, minute: 5, second: 0)
        )

        let screenshot = makeProcessedScreenshot(context: context)
        let fileName = FileOrganizer.generateFileName(for: screenshot)

        XCTAssertEqual(fileName, "SnapNote_09-05-00_Unknown.png")
    }

    func testGenerateFileName_appNameWithSpaces() {
        let context = CaptureContext(
            mode: .window,
            sourceAppName: "VS Code",
            timestamp: makeDate(hour: 12, minute: 0, second: 0)
        )

        let screenshot = makeProcessedScreenshot(context: context)
        let fileName = FileOrganizer.generateFileName(for: screenshot)

        XCTAssertEqual(fileName, "SnapNote_12-00-00_VSCode.png")
    }

    func testEnsureBaseDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SnapNoteTest_\(UUID().uuidString)").path

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir))

        try FileOrganizer.ensureBaseDirectory(tempDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir))

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    // MARK: - Helpers

    private func makeDate(hour: Int, minute: Int, second: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 30
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar.current.date(from: components)!
    }

    private func makeProcessedScreenshot(context: CaptureContext) -> ProcessedScreenshot {
        // Create a minimal 1x1 CGImage
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let cgContext = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )!
        let cgImage = cgContext.makeImage()!
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 1, height: 1))

        return ProcessedScreenshot(
            image: nsImage,
            cgImage: cgImage,
            pngData: Data(),
            context: context
        )
    }
}
