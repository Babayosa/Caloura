import XCTest
@testable import Caloura

final class AnnotationCoordTransformTests: XCTestCase {

    // MARK: - Scale

    func testScale_imageMatchesCanvas_returnsOne() {
        let t = AnnotationCoordTransform(imageSize: CGSize(width: 800, height: 600),
                                         canvasSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(t.scale, 1.0, accuracy: 0.001)
    }

    func testScale_imageLargerThanCanvas_returnsRatio() {
        let t = AnnotationCoordTransform(imageSize: CGSize(width: 1920, height: 1080),
                                         canvasSize: CGSize(width: 800, height: 450))
        // 1920 / 800 = 2.4
        XCTAssertEqual(t.scale, 2.4, accuracy: 0.001)
    }

    // MARK: - Image Frame

    func testImageFrame_perfectFit_noLetterboxing() {
        let t = AnnotationCoordTransform(imageSize: CGSize(width: 1920, height: 1080),
                                         canvasSize: CGSize(width: 800, height: 450))
        let frame = t.imageFrame
        XCTAssertEqual(frame.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(frame.width, 800, accuracy: 0.001)
        XCTAssertEqual(frame.height, 450, accuracy: 0.001)
    }

    func testImageFrame_verticalLetterbox() {
        // Wide image in a square canvas → letterboxing top/bottom
        let t = AnnotationCoordTransform(imageSize: CGSize(width: 1920, height: 1080),
                                         canvasSize: CGSize(width: 800, height: 800))
        let frame = t.imageFrame
        XCTAssertEqual(frame.width, 800, accuracy: 0.001)
        XCTAssertEqual(frame.height, 450, accuracy: 0.001)
        XCTAssertEqual(frame.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 175, accuracy: 0.001) // (800-450)/2
    }

    func testImageFrame_horizontalLetterbox() {
        // Tall image in a square canvas → letterboxing left/right
        let t = AnnotationCoordTransform(imageSize: CGSize(width: 1080, height: 1920),
                                         canvasSize: CGSize(width: 800, height: 800))
        let frame = t.imageFrame
        XCTAssertEqual(frame.height, 800, accuracy: 0.001)
        XCTAssertEqual(frame.width, 450, accuracy: 0.001)
        XCTAssertEqual(frame.origin.x, 175, accuracy: 0.001) // (800-450)/2
        XCTAssertEqual(frame.origin.y, 0, accuracy: 0.001)
    }

    // MARK: - viewToImage

    func testViewToImage_identity_whenCanvasMatchesImage() {
        let t = AnnotationCoordTransform(imageSize: CGSize(width: 800, height: 600),
                                         canvasSize: CGSize(width: 800, height: 600))
        let result = t.viewToImage(CGPoint(x: 400, y: 300))
        XCTAssertEqual(result.x, 400, accuracy: 0.001)
        XCTAssertEqual(result.y, 300, accuracy: 0.001)
    }

    func testViewToImage_scaledDown() {
        // 1920x1080 image displayed at 800x450 (perfect aspect)
        let t = AnnotationCoordTransform(imageSize: CGSize(width: 1920, height: 1080),
                                         canvasSize: CGSize(width: 800, height: 450))
        let result = t.viewToImage(CGPoint(x: 400, y: 225))
        XCTAssertEqual(result.x, 960, accuracy: 0.001)
        XCTAssertEqual(result.y, 540, accuracy: 0.001)
    }

    func testViewToImage_topLeftCorner() {
        let t = AnnotationCoordTransform(imageSize: CGSize(width: 1920, height: 1080),
                                         canvasSize: CGSize(width: 800, height: 450))
        let result = t.viewToImage(CGPoint(x: 0, y: 0))
        XCTAssertEqual(result.x, 0, accuracy: 0.001)
        XCTAssertEqual(result.y, 0, accuracy: 0.001)
    }

    func testViewToImage_withVerticalLetterbox() {
        // 1920x1080 in 800x800 canvas → image at (0, 175, 800, 450)
        let t = AnnotationCoordTransform(imageSize: CGSize(width: 1920, height: 1080),
                                         canvasSize: CGSize(width: 800, height: 800))
        // Point at image's top-left corner in view-space: (0, 175)
        let topLeft = t.viewToImage(CGPoint(x: 0, y: 175))
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.001)

        // Center of image in view-space: (400, 400)
        let center = t.viewToImage(CGPoint(x: 400, y: 400))
        XCTAssertEqual(center.x, 960, accuracy: 0.001)
        XCTAssertEqual(center.y, 540, accuracy: 0.001)
    }

    func testViewToImage_withHorizontalLetterbox() {
        // 1080x1920 in 800x800 canvas → image at (175, 0, 450, 800)
        let t = AnnotationCoordTransform(imageSize: CGSize(width: 1080, height: 1920),
                                         canvasSize: CGSize(width: 800, height: 800))
        // Point at image's top-left corner in view-space: (175, 0)
        let topLeft = t.viewToImage(CGPoint(x: 175, y: 0))
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.001)
    }

    // MARK: - Edge Cases

    func testViewToImage_zeroCanvasSize_returnsOriginal() {
        let t = AnnotationCoordTransform(imageSize: CGSize(width: 1920, height: 1080),
                                         canvasSize: .zero)
        let result = t.viewToImage(CGPoint(x: 100, y: 200))
        XCTAssertEqual(result.x, 100, accuracy: 0.001)
        XCTAssertEqual(result.y, 200, accuracy: 0.001)
    }

    func testScale_zeroCanvasSize_returnsOne() {
        let t = AnnotationCoordTransform(imageSize: CGSize(width: 1920, height: 1080),
                                         canvasSize: .zero)
        XCTAssertEqual(t.scale, 1.0, accuracy: 0.001)
    }
}
