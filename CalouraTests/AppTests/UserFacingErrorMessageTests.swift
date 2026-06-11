import XCTest
@testable import Caloura

final class UserFacingErrorMessageTests: XCTestCase {

    // MARK: Network errors

    func testNetworkErrorCodes_mapToConnectionMessage() {
        let codes = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorSecureConnectionFailed,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired,
            NSURLErrorCannotLoadFromNetwork
        ]
        for code in codes {
            let error = NSError(domain: NSURLErrorDomain, code: code, userInfo: [
                NSLocalizedDescriptionKey: "An SSL error has occurred."
            ])
            XCTAssertEqual(
                UserFacingErrorMessage.message(for: error),
                "Could not connect. Check your internet connection and try again.",
                "code \(code) should map to the connection message"
            )
        }
    }

    func testNonNetworkURLErrorCode_keepsDescription() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [
            NSLocalizedDescriptionKey: "bad URL"
        ])
        XCTAssertEqual(UserFacingErrorMessage.message(for: error), "bad URL")
    }

    func testNetworkCodeInOtherDomain_keepsDescription() {
        let error = NSError(domain: "custom", code: NSURLErrorTimedOut, userInfo: [
            NSLocalizedDescriptionKey: "custom timeout"
        ])
        XCTAssertEqual(UserFacingErrorMessage.message(for: error), "custom timeout")
    }

    // MARK: Clipboard errors

    func testPasteboardDomain_mapsToClipboardMessage() {
        let error = NSError(domain: "NSPasteboardErrorDomain", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "write failed"
        ])
        XCTAssertEqual(
            UserFacingErrorMessage.message(for: error),
            "Could not copy to the clipboard. Try again."
        )
    }

    func testClipboardDescription_mapsToClipboardMessage() {
        let error = NSError(domain: "custom", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "Could not write image to the clipboard"
        ])
        XCTAssertEqual(
            UserFacingErrorMessage.message(for: error),
            "Could not copy to the clipboard. Try again."
        )
    }

    // MARK: Fallbacks

    func testEmptyDescription_fallsBackToGenericMessage() {
        let error = NSError(domain: "custom", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "   \n"
        ])
        XCTAssertEqual(
            UserFacingErrorMessage.message(for: error),
            "Something went wrong. Try again."
        )
    }

    func testOtherError_passesDescriptionThroughTrimmed() {
        let error = NSError(domain: "custom", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "  Disk is full.  "
        ])
        XCTAssertEqual(UserFacingErrorMessage.message(for: error), "Disk is full.")
    }

    // MARK: UpdateErrorSnapshot overload

    func testUpdateErrorSnapshot_networkError_mapsToConnectionMessage() {
        let snapshot = UpdateErrorSnapshot(error: NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
        ))
        XCTAssertEqual(
            UserFacingErrorMessage.message(for: snapshot),
            "Could not connect. Check your internet connection and try again."
        )
    }

    func testUpdateErrorSnapshot_otherError_keepsDescription() {
        let snapshot = UpdateErrorSnapshot(error: NSError(
            domain: "network",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "The appcast could not be loaded."]
        ))
        XCTAssertEqual(
            UserFacingErrorMessage.message(for: snapshot),
            "The appcast could not be loaded."
        )
    }
}
