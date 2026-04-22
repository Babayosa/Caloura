import XCTest
@testable import Caloura

/// Phase 3.8 tests for `DiagnosticsReporter.rotateOldPayloads`.
///
/// Verifies the 30-day retention policy: payloads older than the cutoff are
/// removed, recent payloads survive, and a missing/empty directory is a no-op
/// rather than a crash.
@MainActor
final class DiagnosticsReporterTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-rotate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    private func writePayload(name: String, ageDays: Double) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url)
        let modified = Date().addingTimeInterval(-ageDays * 86_400)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: url.path
        )
        return url
    }

    func testRotation_removesPayloadsOlderThanRetentionWindow() throws {
        let stale = try writePayload(name: "stale.json", ageDays: 45)
        let onCusp = try writePayload(name: "cusp.json", ageDays: 31)
        let recent = try writePayload(name: "recent.json", ageDays: 5)

        DiagnosticsReporter.rotateOldPayloads(
            in: tempDir,
            retentionDays: 30,
            now: Date(),
            fileManager: .default
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: onCusp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testRotation_keepsAllPayloadsInsideRetentionWindow() throws {
        let oneDay = try writePayload(name: "one-day.json", ageDays: 1)
        let twentyNine = try writePayload(name: "twenty-nine.json", ageDays: 29)

        DiagnosticsReporter.rotateOldPayloads(
            in: tempDir,
            retentionDays: 30,
            now: Date(),
            fileManager: .default
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: oneDay.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: twentyNine.path))
    }

    func testRotation_emptyDirectoryIsNoOp() {
        DiagnosticsReporter.rotateOldPayloads(
            in: tempDir,
            retentionDays: 30,
            now: Date(),
            fileManager: .default
        )

        let contents = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(contents?.count, 0)
    }

    func testRotation_missingDirectoryDoesNotCrash() {
        let missing = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)

        DiagnosticsReporter.rotateOldPayloads(
            in: missing,
            retentionDays: 30,
            now: Date(),
            fileManager: .default
        )
        // Reaching here without crashing is the assertion.
    }

    func testRotation_honorsExplicitNowParameter() throws {
        // 10-day-old file, but pretend "now" is 60 days in the future →
        // the file is effectively 70 days old and should be evicted.
        let payload = try writePayload(name: "shifted.json", ageDays: 10)
        let futureNow = Date().addingTimeInterval(60 * 86_400)

        DiagnosticsReporter.rotateOldPayloads(
            in: tempDir,
            retentionDays: 30,
            now: futureNow,
            fileManager: .default
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
    }
}
