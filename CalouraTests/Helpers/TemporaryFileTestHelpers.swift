import Foundation
import XCTest

/// Shared temp-path helpers. Every URL handed out is registered for removal
/// in test teardown, so neither assertion failures nor early returns can
/// leak files into the system temporary directory.
extension XCTestCase {
    /// Unique file URL under the system temp directory; removed on teardown.
    /// The file itself is not created.
    func temporaryFileURL(prefix: String, fileExtension: String = "json") -> URL {
        registeredForRemoval(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix)-\(UUID().uuidString).\(fileExtension)")
        )
    }

    /// Unique directory URL under the system temp directory; removed
    /// recursively on teardown. The directory itself is not created.
    func temporaryDirectoryURL(prefix: String = "caloura-test") -> URL {
        registeredForRemoval(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        )
    }

    private func registeredForRemoval(_ url: URL) -> URL {
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
