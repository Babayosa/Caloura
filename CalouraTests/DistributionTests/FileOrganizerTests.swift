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

        let fileName = FileOrganizer.generateFileName(for: context)

        XCTAssertEqual(fileName, "Caloura_14-30-45-000_Safari.png")
    }

    func testGenerateFileName_withoutAppName() {
        let context = CaptureContext(
            mode: .fullscreen,
            sourceAppName: nil,
            timestamp: makeDate(hour: 9, minute: 5, second: 0)
        )

        let fileName = FileOrganizer.generateFileName(for: context)

        XCTAssertEqual(fileName, "Caloura_09-05-00-000_Unknown.png")
    }

    func testGenerateFileName_appNameWithSpaces() {
        let context = CaptureContext(
            mode: .window,
            sourceAppName: "VS Code",
            timestamp: makeDate(hour: 12, minute: 0, second: 0)
        )

        let fileName = FileOrganizer.generateFileName(for: context)

        XCTAssertEqual(fileName, "Caloura_12-00-00-000_VSCode.png")
    }

    func testEnsureBaseDirectory() throws {
        let tempDir = temporaryDirectoryURL(prefix: "CalouraTest").path

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir))

        try FileOrganizer.ensureBaseDirectory(tempDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir))
    }

    // MARK: - Save writes to disk

    func testSave_writesFileToDisk() async throws {
        let tempDir = temporaryDirectoryURL(prefix: "CalouraTest")

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
        let tempDir = temporaryDirectoryURL(prefix: "CalouraTest")

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
        let fileName = FileOrganizer.generateFileName(for: context)

        XCTAssertFalse(fileName.contains("/"), "Filename should not contain slashes")
        XCTAssertEqual(fileName, "Caloura_08-00-00-000_AppWithSlashes.png")
    }

    // MARK: - Path Traversal Safety

    func testSave_pathTraversal_dotDotSubfolder_throws() async {
        let tempDir = temporaryDirectoryURL(prefix: "CalouraTest")

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
        let tempDir = temporaryDirectoryURL(prefix: "CalouraTest")

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
        let tempDir = temporaryDirectoryURL(prefix: "CalouraTest")

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
        let tempDir = temporaryDirectoryURL(prefix: "CalouraTest")

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
        let tempDir = temporaryDirectoryURL(prefix: "CalouraTest")

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

    // MARK: - File Permissions

    func testSave_fileHasRestrictedPermissions() async throws {
        let tempDir = temporaryDirectoryURL(prefix: "CalouraTest")

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

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "Saved file should have 0600 permissions")
    }

    func testSave_directoryHasRestrictedPermissions() async throws {
        let tempDir = temporaryDirectoryURL(prefix: "CalouraTest")

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

        let dirPath = fileURL.deletingLastPathComponent().path
        let attrs = try FileManager.default.attributesOfItem(atPath: dirPath)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700, "Created directory should have 0700 permissions")
    }

    // MARK: - JPEG Format

    func testSave_jpegFormat_createsFile() async throws {
        let tempDir = temporaryDirectoryURL(prefix: "CalouraTest")

        let context = CaptureContext(
            mode: .area,
            sourceAppName: "TestApp",
            timestamp: makeDate(hour: 11, minute: 0, second: 0)
        )
        let screenshot = makeProcessedScreenshot(context: context)

        let fileURL = try await FileOrganizer.save(
            screenshot,
            baseDirectory: tempDir.path,
            subfolder: nil,
            imageFormat: "jpeg"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(fileURL.lastPathComponent.hasSuffix(".jpeg"))
    }

    func testSave_smartFileNameCollision_appendsUniqueSuffix() async throws {
        let tempDir = temporaryDirectoryURL(prefix: "CalouraTest")

        let context = CaptureContext(
            mode: .area,
            sourceAppName: "TestApp",
            timestamp: makeDate(hour: 11, minute: 0, second: 0)
        )
        let screenshot = makeProcessedScreenshot(context: context)

        let firstURL = try await FileOrganizer.save(
            cgImage: screenshot.cgImage,
            context: screenshot.context,
            baseDirectory: tempDir.path,
            smartFileName: "release-notes"
        )
        let secondURL = try await FileOrganizer.save(
            cgImage: screenshot.cgImage,
            context: screenshot.context,
            baseDirectory: tempDir.path,
            smartFileName: "release-notes"
        )

        XCTAssertNotEqual(firstURL.lastPathComponent, secondURL.lastPathComponent)
        XCTAssertEqual(firstURL.lastPathComponent, "release-notes.png")
        XCTAssertEqual(secondURL.lastPathComponent, "release-notes-2.png")
    }

    // MARK: - Symlink Escape

    func testSave_symlinkEscape_throws() async throws {
        let tempDir = temporaryDirectoryURL(prefix: "CalouraTest")
        let escapeTarget = temporaryDirectoryURL(prefix: "CalouraEscape")

        // Create the base directory and a symlink subfolder pointing outside
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: escapeTarget, withIntermediateDirectories: true
        )
        let symlinkPath = tempDir.appendingPathComponent("evil-link")
        try FileManager.default.createSymbolicLink(
            at: symlinkPath, withDestinationURL: escapeTarget
        )

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
                subfolder: "evil-link"
            )
            XCTFail("Expected pathTraversal error for symlink escape")
        } catch let error as FileOrganizer.FileOrganizerError {
            XCTAssertEqual(error, .pathTraversal)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - File Name Generation Details

    func testGenerateFileName_containsTimestamp() {
        let context = CaptureContext(
            mode: .area,
            sourceAppName: "TestApp",
            timestamp: makeDate(hour: 23, minute: 59, second: 59)
        )
        let fileName = FileOrganizer.generateFileName(for: context)

        XCTAssertTrue(
            fileName.contains("23-59-59-000"),
            "Filename should contain HH-mm-ss-SSS timestamp"
        )
    }

    // MARK: - Sanitization

    func testSanitizeFileName_removesUnsafeCharacters() {
        XCTAssertEqual(
            FileOrganizer.sanitizeFileName("Hello World!"),
            "HelloWorld"
        )
        XCTAssertEqual(
            FileOrganizer.sanitizeFileName("file/with/slashes"),
            "filewithslashes"
        )
        XCTAssertEqual(
            FileOrganizer.sanitizeFileName("special@#$chars"),
            "specialchars"
        )
        XCTAssertEqual(
            FileOrganizer.sanitizeFileName("keep-hyphens"),
            "keep-hyphens"
        )
    }

    func testSanitizeFileName_emptyInput_returnsUnknown() {
        XCTAssertEqual(FileOrganizer.sanitizeFileName(""), "Unknown")
        XCTAssertEqual(FileOrganizer.sanitizeFileName("!!!"), "Unknown")
    }

    func testSanitizeFileName_truncatesLongNames() {
        let longName = String(repeating: "a", count: 100)
        let sanitized = FileOrganizer.sanitizeFileName(longName)
        XCTAssertEqual(sanitized.count, 50)
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
