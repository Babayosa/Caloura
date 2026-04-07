import Foundation
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import Caloura

final class ScreenCaptureManagerPermissionProbeTests: XCTestCase {
    func testProbeSCKAccessViaMinimalScreenshot_emptyBoundsReturnsTransientFailure() async {
        let result = await ScreenCaptureManager.probeSCKAccessViaMinimalScreenshot(
            displayBoundsProvider: { .zero },
            screenshotProbe: { _ in
                XCTFail("Probe should not run when bounds are empty")
            }
        )

        XCTAssertEqual(result, .transientFailure)
    }

    func testProbeSCKAccessViaMinimalScreenshot_authorizedUsesMinimalProbeRect() async {
        let bounds = CGRect(x: 40, y: 60, width: 100, height: 80)
        let box = ProbeRectBox()

        let result = await ScreenCaptureManager.probeSCKAccessViaMinimalScreenshot(
            displayBoundsProvider: { bounds },
            screenshotProbe: { rect in
                box.rect = rect
            }
        )

        XCTAssertEqual(result, .authorized)
        XCTAssertEqual(box.rect, CGRect(x: 41, y: 61, width: 2, height: 2))
    }

    func testProbeSCKAccessViaMinimalScreenshot_defaultDisplayBoundsProducesProbeRect() async {
        let box = ProbeRectBox()

        let result = await ScreenCaptureManager.probeSCKAccessViaMinimalScreenshot(
            screenshotProbe: { rect in
                box.rect = rect
            }
        )

        XCTAssertEqual(result, .authorized)
        XCTAssertNotNil(box.rect)
        XCTAssertEqual(box.rect?.width, 2)
        XCTAssertEqual(box.rect?.height, 2)
    }

    func testProbeSCKAccessViaMinimalScreenshot_tinyBoundsClampToSinglePixelRect() async {
        let bounds = CGRect(x: 8, y: 10, width: 2, height: 2)
        let box = ProbeRectBox()

        let result = await ScreenCaptureManager.probeSCKAccessViaMinimalScreenshot(
            displayBoundsProvider: { bounds },
            screenshotProbe: { rect in
                box.rect = rect
            }
        )

        XCTAssertEqual(result, .authorized)
        XCTAssertEqual(box.rect, CGRect(x: 9, y: 11, width: 1, height: 1))
    }

    func testProbeSCKAccessViaMinimalScreenshot_userDeclinedReturnsUserDeclined() async {
        let result = await ScreenCaptureManager.probeSCKAccessViaMinimalScreenshot(
            displayBoundsProvider: { CGRect(x: 0, y: 0, width: 40, height: 40) },
            screenshotProbe: { _ in
                throw NSError(
                    domain: SCStreamError.errorDomain,
                    code: SCStreamError.Code.userDeclined.rawValue
                )
            }
        )

        XCTAssertEqual(result, .userDeclined)
    }

    func testProbeSCKAccessViaMinimalScreenshot_genericFailureReturnsTransientFailure() async {
        let result = await ScreenCaptureManager.probeSCKAccessViaMinimalScreenshot(
            displayBoundsProvider: { CGRect(x: 0, y: 0, width: 40, height: 40) },
            screenshotProbe: { _ in
                throw NSError(domain: "tests", code: 42)
            }
        )

        XCTAssertEqual(result, .transientFailure)
    }

    func testCaptureMinimalScreenshot_successResumesWhenImageReturned() async throws {
        try await ScreenCaptureManager.captureMinimalScreenshot(
            in: CGRect(x: 0, y: 0, width: 2, height: 2),
            screenshotCapture: { _, completion in
                completion(
                    TestImageFactory.makeTestImage(width: 2, height: 2),
                    nil
                )
            }
        )
    }

    func testCaptureMinimalScreenshot_nilImageThrowsNoContent() async {
        do {
            try await ScreenCaptureManager.captureMinimalScreenshot(
                in: CGRect(x: 0, y: 0, width: 2, height: 2),
                screenshotCapture: { _, completion in
                    completion(nil, nil)
                }
            )
            XCTFail("Expected noContent when screenshot probe returns nil image")
        } catch let error as CaptureError {
            guard case .noContent(let source) = error else {
                return XCTFail("Expected CaptureError.noContent, got \(error)")
            }
            XCTAssertEqual(source, "ScreenCaptureKit permission probe")
        } catch {
            XCTFail("Expected CaptureError.noContent, got \(error)")
        }
    }

    func testCaptureMinimalScreenshot_propagatesUnderlyingError() async {
        let underlyingError = NSError(
            domain: "tests",
            code: 77,
            userInfo: [NSLocalizedDescriptionKey: "probe failed"]
        )

        do {
            try await ScreenCaptureManager.captureMinimalScreenshot(
                in: CGRect(x: 0, y: 0, width: 2, height: 2),
                screenshotCapture: { _, completion in
                    completion(nil, underlyingError)
                }
            )
            XCTFail("Expected screenshot probe error to be thrown")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, underlyingError.domain)
            XCTAssertEqual(error.code, underlyingError.code)
        } catch {
            XCTFail("Expected NSError, got \(error)")
        }
    }
}

private final class ProbeRectBox: @unchecked Sendable {
    var rect: CGRect?
}
