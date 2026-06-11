import CoreGraphics
import CoreText
import XCTest
@testable import Caloura

/// Phase 3.0 baseline for audit finding 3.2: double full-image Vision pass per
/// PII-enabled enrichment.
///
/// Code-inspection evidence (recorded 2026-06-11):
/// - On `origin/main` (8e2bdc9) `OCREngine.recognizeTextWithBoundingBoxes`
///   performs a SINGLE `.accurate` `VNRecognizeTextRequest`
///   (`OCREngine.swift:60` request, `:76` `.accurate`).
/// - The two-pass variant exists on `origin/task-22-window-sharing-stealth`
///   (f706522): `performOCRWithBoundingBoxes` first runs a `.fast` probe
///   (`fastOCRFindsText`, OCREngine.swift:58 call, :90 request, :97 `.fast`)
///   and then the `.accurate` pass (:62 request, :78 `.accurate`).
///
/// This test measures both recognition levels on the same generated text image
/// so the probe's added cost (fast + accurate vs accurate alone) is quantified.
final class PerfBaselineOCRTests: XCTestCase {

    func testBaseline_singleEnrichmentOCRPass_sampleImage() async throws {
        let image = Self.makeTextImage(
            width: 800,
            height: 600,
            lines: [
                "Quarterly revenue report 2026",
                "Contact: ops team, building 4",
                "Invoice total 1234.56 approved",
                "Meeting notes captured by Caloura",
                "The quick brown fox jumps over the lazy dog"
            ]
        )

        // Verify Vision actually reads the drawn text before timing anything.
        let probeObservations = try await OCREngine.recognizeTextWithBoundingBoxes(in: image)
        if probeObservations.isEmpty {
            throw XCTSkip("Vision found no text in the generated sample image on this environment")
        }

        let accurateStats = try await PerfBaselineMeasurement.measureAsync(warmup: 1, iterations: 5) {
            _ = try await OCREngine.recognizeTextWithBoundingBoxes(in: image)
        }
        let fastStats = try await PerfBaselineMeasurement.measureAsync(warmup: 1, iterations: 5) {
            _ = try await OCREngine.recognizeText(in: image)
        }

        print(PerfBaselineMeasurement.summary(
            "OCR accurate-pass (recognizeTextWithBoundingBoxes) image=800x600"
                + " observations=\(probeObservations.count)",
            accurateStats
        ))
        print(PerfBaselineMeasurement.summary(
            "OCR fast-pass (recognizeText) image=800x600",
            fastStats
        ))
        let doublePassMS = fastStats.medianMS + accurateStats.medianMS
        print(String(
            format: "[perf-baseline] OCR double-pass estimate (fast probe + accurate)"
                + " median=%.3fms vs single accurate median=%.3fms (probe overhead=%.3fms)",
            doublePassMS,
            accurateStats.medianMS,
            fastStats.medianMS
        ))

        XCTAssertLessThan(accurateStats.meanMS, 30_000, "Sanity bound only — not a perf gate")
        XCTAssertLessThan(fastStats.meanMS, 30_000, "Sanity bound only — not a perf gate")
    }

    /// Draws lines of black Helvetica text on a white background via CoreText.
    private static func makeTextImage(width: Int, height: Int, lines: [String]) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            preconditionFailure("Failed to create CGContext for sample text image")
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]

        var baselineY = CGFloat(height) - 60
        for line in lines {
            guard let attributed = CFAttributedStringCreate(
                nil,
                line as CFString,
                attributes as CFDictionary
            ) else { continue }
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 40, y: baselineY)
            CTLineDraw(ctLine, context)
            baselineY -= 50
        }

        guard let image = context.makeImage() else {
            preconditionFailure("Failed to render sample text image")
        }
        return image
    }
}
