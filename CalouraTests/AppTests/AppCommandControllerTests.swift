import XCTest
@testable import Caloura

@MainActor
final class AppCommandControllerTests: XCTestCase {

    func testHandle_captureCommandsRouteToPipelineMethods() {
        var recorded: [RecordedRoute] = []
        let controller = makeController { recorded.append($0) }

        controller.handle(.captureArea)
        controller.handle(.captureWindow)
        controller.handle(.captureFullscreen)
        controller.handle(.captureRepeat)
        controller.handle(.cancelDelayedCapture)

        XCTAssertEqual(
            recorded,
            [
                .captureArea,
                .captureWindow,
                .captureFullscreen,
                .captureRepeat,
                .cancelDelayedCapture
            ]
        )
    }

    func testHandle_distributionCommandsRouteToPipelineMethods() {
        var recorded: [RecordedRoute] = []
        let controller = makeController { recorded.append($0) }

        controller.handle(.copyLastImage)
        controller.handle(.copyLastAsMarkdown)
        controller.handle(.copyLastWithCitation)
        controller.handle(.copyLastOCRText)
        controller.handle(.saveLastCapture)

        XCTAssertEqual(
            recorded,
            [
                .copyLastImage,
                .copyLastAsMarkdown,
                .copyLastWithCitation,
                .copyLastOCRText,
                .saveLastCapture
            ]
        )
    }

    private func makeController(
        record: @escaping (RecordedRoute) -> Void
    ) -> AppCommandController {
        AppCommandController(
            onboardingController: OnboardingWindowController(),
            historyController: HistoryWindowController(),
            annotationController: AnnotationWindowController(),
            routing: AppCommandController.Routing(
                captureArea: { record(.captureArea) },
                captureWindow: { record(.captureWindow) },
                captureFullscreen: { record(.captureFullscreen) },
                captureRepeat: { record(.captureRepeat) },
                captureDelayed: { mode, seconds in
                    record(.captureDelayed(mode: mode, seconds: seconds))
                },
                cancelDelayedCapture: { record(.cancelDelayedCapture) },
                copyLastImage: { record(.copyLastImage) },
                copyLastAsMarkdown: { record(.copyLastAsMarkdown) },
                copyLastWithCitation: { record(.copyLastWithCitation) },
                copyLastOCRText: { record(.copyLastOCRText) },
                saveLastCapture: { record(.saveLastCapture) },
                showTip: { tip in record(.tip(tip.rawValue)) }
            )
        )
    }
}

private enum RecordedRoute: Equatable {
    case captureArea
    case captureWindow
    case captureFullscreen
    case captureRepeat
    case captureDelayed(mode: CaptureMode, seconds: Int)
    case cancelDelayedCapture
    case copyLastImage
    case copyLastAsMarkdown
    case copyLastWithCitation
    case copyLastOCRText
    case saveLastCapture
    case tip(String)
}
