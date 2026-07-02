import XCTest
@testable import Caloura

/// Base case for tests that exercise `HistoryCrypto`-backed persistence
/// (encrypted `save`/`load`/`flush`).
///
/// Redirects the history root key to a throwaway per-test directory so encrypted
/// round-trips never touch the real login keychain, never leave a persistent
/// `history-root-key-v1` item behind, and never couple results to keychain
/// state/order or hard-fail where keychain access is denied (audit M7).
class CryptoIsolatedTestCase: XCTestCase {
    private var cryptoSecurityDir: URL!

    override func setUp() {
        super.setUp()
        cryptoSecurityDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalouraCryptoIsolated_\(UUID().uuidString)")
        HistoryCrypto.setSecurityDirectoryForTesting(cryptoSecurityDir)
        HistoryCrypto.resetCachedKeyForTesting()
    }

    override func tearDown() {
        HistoryCrypto.setSecurityDirectoryForTesting(nil)
        HistoryCrypto.resetCachedKeyForTesting()
        if let cryptoSecurityDir {
            try? FileManager.default.removeItem(at: cryptoSecurityDir)
        }
        super.tearDown()
    }
}
