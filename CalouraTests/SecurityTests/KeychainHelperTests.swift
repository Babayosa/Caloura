import Security
import XCTest
@testable import Caloura

/// Phase 3.9 tests for `KeychainHelper.isInteractionRequiredStatus`.
///
/// The classifier feeds the user-facing branch that prompts for keychain
/// unlock vs surfaces a generic failure. Mis-classifying either side
/// either spams the user with prompts they can't satisfy or hides a real
/// keychain corruption, so the matrix needs an explicit guard.
final class KeychainHelperTests: XCTestCase {

    // MARK: - Statuses that MUST prompt for interaction

    func testInteractionRequiredOnInteractionNotAllowed() {
        XCTAssertTrue(KeychainHelper.isInteractionRequiredStatus(errSecInteractionNotAllowed))
    }

    func testInteractionRequiredOnUserCanceled() {
        XCTAssertTrue(KeychainHelper.isInteractionRequiredStatus(errSecUserCanceled))
    }

    func testInteractionRequiredOnAuthFailed() {
        XCTAssertTrue(KeychainHelper.isInteractionRequiredStatus(errSecAuthFailed))
    }

    // MARK: - Statuses that MUST NOT prompt for interaction

    func testInteractionNotRequiredOnSuccess() {
        XCTAssertFalse(KeychainHelper.isInteractionRequiredStatus(errSecSuccess))
    }

    func testInteractionNotRequiredOnItemNotFound() {
        XCTAssertFalse(KeychainHelper.isInteractionRequiredStatus(errSecItemNotFound))
    }

    func testInteractionNotRequiredOnDuplicateItem() {
        XCTAssertFalse(KeychainHelper.isInteractionRequiredStatus(errSecDuplicateItem))
    }

    func testInteractionNotRequiredOnDecode() {
        XCTAssertFalse(KeychainHelper.isInteractionRequiredStatus(errSecDecode))
    }

    func testInteractionNotRequiredOnAllocate() {
        XCTAssertFalse(KeychainHelper.isInteractionRequiredStatus(errSecAllocate))
    }

    func testInteractionNotRequiredOnArbitraryNonZeroStatus() {
        // Defensive guard: any unrecognized non-zero status must default to
        // .failure rather than .interactionRequired, otherwise a totally
        // unrelated error would trigger the unlock prompt path.
        XCTAssertFalse(KeychainHelper.isInteractionRequiredStatus(-99_999))
        XCTAssertFalse(KeychainHelper.isInteractionRequiredStatus(errSecParam))
    }
}
