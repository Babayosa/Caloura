import XCTest
@testable import Caloura

/// Pins the State Machines / Recovery convention for the beautify + redaction
/// overlay models: a cancelled in-flight operation must not publish a stale
/// result and must always clear its in-progress flag (defer-based clear).
@MainActor
final class OverlayCancellationRecoveryTests: XCTestCase {

    // MARK: BeautifyPreviewModel

    func testBeautify_cancelledRun_doesNotPublishStaleResultAndClearsFlag() async {
        let image = TestImageFactory.makeTestImage()
        let model = BeautifyPreviewModel(beautify: { source, _ in
            try? await Task.sleep(for: .seconds(30))
            return source
        })

        let task = Task {
            await model.generatePreview(from: image, theme: BeautifyTheme.builtInThemes[0])
        }
        task.cancel()
        await task.value

        XCTAssertNil(model.previewImage, "cancelled generate must not publish a stale preview")
        XCTAssertFalse(model.isProcessing, "isProcessing must be cleared after a cancelled run")
    }

    func testBeautify_completedRun_publishesResultAndClearsFlag() async {
        let image = TestImageFactory.makeTestImage()
        let model = BeautifyPreviewModel(beautify: { source, _ in source })

        await model.generatePreview(from: image, theme: BeautifyTheme.builtInThemes[0])

        XCTAssertNotNil(model.previewImage)
        XCTAssertFalse(model.isProcessing)
    }

    // MARK: RedactionReviewModel

    func testRedaction_cancelledRun_doesNotPublishStaleResultAndClearsFlag() async {
        let image = TestImageFactory.makeTestImage()
        let model = RedactionReviewModel(redact: { source, _ in
            try? await Task.sleep(for: .seconds(30))
            return source
        })

        let task = Task {
            await model.applyRedaction(source: image, regions: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        }
        task.cancel()
        await task.value

        XCTAssertNil(model.redactedImage, "cancelled redaction must not publish a stale image")
        XCTAssertFalse(model.hasRedacted, "cancelled redaction must not flip hasRedacted")
        XCTAssertFalse(model.isRedacting, "isRedacting must be cleared after a cancelled run")
    }

    func testRedaction_completedRun_publishesResultAndClearsFlag() async {
        let image = TestImageFactory.makeTestImage()
        let model = RedactionReviewModel(redact: { source, _ in source })

        await model.applyRedaction(source: image, regions: [CGRect(x: 0, y: 0, width: 1, height: 1)])

        XCTAssertNotNil(model.redactedImage)
        XCTAssertTrue(model.hasRedacted)
        XCTAssertFalse(model.isRedacting)
    }
}
