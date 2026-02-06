import XCTest
@testable import Caloura

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

        XCTAssertEqual(fileName, "Caloura_14-30-45_Safari.png")
    }

    func testGenerateFileName_withoutAppName() {
        let context = CaptureContext(
            mode: .fullscreen,
            sourceAppName: nil,
            timestamp: makeDate(hour: 9, minute: 5, second: 0)
        )

        let screenshot = makeProcessedScreenshot(context: context)
        let fileName = FileOrganizer.generateFileName(for: screenshot)

        XCTAssertEqual(fileName, "Caloura_09-05-00_Unknown.png")
    }

    func testGenerateFileName_appNameWithSpaces() {
        let context = CaptureContext(
            mode: .window,
            sourceAppName: "VS Code",
            timestamp: makeDate(hour: 12, minute: 0, second: 0)
        )

        let screenshot = makeProcessedScreenshot(context: context)
        let fileName = FileOrganizer.generateFileName(for: screenshot)

        XCTAssertEqual(fileName, "Caloura_12-00-00_VSCode.png")
    }

    func testEnsureBaseDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalouraTest_\(UUID().uuidString)").path

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir))

        try FileOrganizer.ensureBaseDirectory(tempDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir))

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    // MARK: - Save writes to disk

    func testSave_writesFileToDisk() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalouraTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = CaptureContext(
            mode: .area,
            sourceAppName: "TestApp",
            timestamp: makeDate(hour: 10, minute: 0, second: 0)
        )
        let screenshot = makeProcessedScreenshot(context: context)

        let fileURL = try await FileOrganizer.save(
            screenshot,
            baseDirectory: tempDir.path,
            subfolder: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(fileURL.lastPathComponent.contains("TestApp"))
    }

    // MARK: - Creates subfolder

    func testSave_createsSubfolder() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalouraTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = CaptureContext(
            mode: .area,
            sourceAppName: "Safari",
            timestamp: makeDate(hour: 15, minute: 30, second: 0)
        )
        let screenshot = makeProcessedScreenshot(context: context)

        let fileURL = try await FileOrganizer.save(
            screenshot,
            baseDirectory: tempDir.path,
            subfolder: "Lectures"
        )

        XCTAssertTrue(fileURL.path.contains("Lectures"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Special characters in app name

    func testGenerateFileName_appNameWithSlash() {
        let context = CaptureContext(
            mode: .area,
            sourceAppName: "App/With/Slashes",
            timestamp: makeDate(hour: 8, minute: 0, second: 0)
        )
        let screenshot = makeProcessedScreenshot(context: context)
        let fileName = FileOrganizer.generateFileName(for: screenshot)

        XCTAssertFalse(fileName.contains("/"), "Filename should not contain slashes")
        XCTAssertEqual(fileName, "Caloura_08-00-00_AppWithSlashes.png")
    }

    // MARK: - Path Traversal Safety

    func testSave_pathTraversal_dotDotSubfolder_throws() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalouraTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = CaptureContext(
            mode: .area,
            sourceAppName: "TestApp",
            timestamp: makeDate(hour: 10, minute: 0, second: 0)
        )
        let screenshot = makeProcessedScreenshot(context: context)

        do {
            _ = try await FileOrganizer.save(
                screenshot,
                baseDirectory: tempDir.path,
                subfolder: "../../tmp/evil"
            )
            XCTFail("Expected pathTraversal error")
        } catch let error as FileOrganizer.FileOrganizerError {
            XCTAssertEqual(error, .pathTraversal)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSave_pathTraversal_normalThenDotDot_throws() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalouraTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = CaptureContext(
            mode: .area,
            sourceAppName: "TestApp",
            timestamp: makeDate(hour: 10, minute: 0, second: 0)
        )
        let screenshot = makeProcessedScreenshot(context: context)

        do {
            _ = try await FileOrganizer.save(
                screenshot,
                baseDirectory: tempDir.path,
                subfolder: "normal/../../../etc"
            )
            XCTFail("Expected pathTraversal error")
        } catch let error as FileOrganizer.FileOrganizerError {
            XCTAssertEqual(error, .pathTraversal)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSave_normalSubfolder_succeeds() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalouraTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = CaptureContext(
            mode: .area,
            sourceAppName: "TestApp",
            timestamp: makeDate(hour: 10, minute: 0, second: 0)
        )
        let screenshot = makeProcessedScreenshot(context: context)

        let fileURL = try await FileOrganizer.save(
            screenshot,
            baseDirectory: tempDir.path,
            subfolder: "Lectures"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(fileURL.path.hasPrefix(tempDir.path))
    }

    func testSave_pathTraversal_encodedSlash_noEscape() async throws {
        // %2F is percent-encoded slash — URL(fileURLWithPath:) does NOT decode it,
        // so it becomes a literal directory name component, staying within base.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalouraTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = CaptureContext(
            mode: .area,
            sourceAppName: "TestApp",
            timestamp: makeDate(hour: 10, minute: 0, second: 0)
        )
        let screenshot = makeProcessedScreenshot(context: context)

        // %2F in a file path component is treated literally by the file system,
        // not as a directory separator. This should succeed (no traversal).
        let fileURL = try await FileOrganizer.save(
            screenshot,
            baseDirectory: tempDir.path,
            subfolder: "safe%2Fname"
        )

        XCTAssertTrue(fileURL.path.hasPrefix(tempDir.path))
    }

    func testSave_pathTraversal_deepDotDot_throws() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalouraTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = CaptureContext(
            mode: .area,
            sourceAppName: "TestApp",
            timestamp: makeDate(hour: 10, minute: 0, second: 0)
        )
        let screenshot = makeProcessedScreenshot(context: context)

        do {
            _ = try await FileOrganizer.save(
                screenshot,
                baseDirectory: tempDir.path,
                subfolder: "a/b/c/../../../../../../../../tmp"
            )
            XCTFail("Expected pathTraversal error")
        } catch let error as FileOrganizer.FileOrganizerError {
            XCTAssertEqual(error, .pathTraversal)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
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
