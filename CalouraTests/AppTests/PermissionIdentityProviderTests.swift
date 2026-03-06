import XCTest
@testable import Caloura

final class PermissionIdentityProviderTests: XCTestCase {
    func testCurrentIdentityLoadsOffMainThread() async {
        let expected = PermissionTestHelpers.makeIdentity("provider-off-main")
        let provider = PermissionIdentityProvider(
            bundle: .main,
            loader: { _ in
                XCTAssertFalse(Thread.isMainThread)
                return expected
            }
        )

        let identity = await provider.currentIdentity()

        XCTAssertEqual(identity, expected)
    }

    func testCurrentIdentityCachesLoaderResult() async {
        let expected = PermissionTestHelpers.makeIdentity("provider-cache")
        let callCounter = LockedCounter()
        let provider = PermissionIdentityProvider(
            bundle: .main,
            loader: { _ in
                callCounter.increment()
                return expected
            }
        )

        _ = await provider.currentIdentity()
        _ = await provider.currentIdentity()

        XCTAssertEqual(callCounter.value, 1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
