import CoreGraphics
import Vision

extension ScrollCaptureHelpers {
    static func detectStickyHeaderHeight(frames: [PreparedFrame]) -> Int {
        guard frames.count >= 3 else { return 0 }
        let recentFrames = Array(frames.suffix(3))
        let maxRows = min(96, recentFrames.map(\.height).min() ?? 0)
        var stickyRows = 0

        for row in 0..<maxRows {
            let first = rowDifference(recentFrames[0], row, recentFrames[1], row)
            let second = rowDifference(recentFrames[1], row, recentFrames[2], row)
            if first <= 6 && second <= 6 {
                stickyRows += 1
            } else if stickyRows >= 12 {
                return stickyRows
            } else {
                break
            }
        }

        return stickyRows >= 12 ? stickyRows : 0
    }

    static func sharedTopRows(
        previous: PreparedFrame,
        current: PreparedFrame
    ) -> Int {
        let maxRows = min(96, previous.height, current.height)
        var stickyRows = 0
        for row in 0..<maxRows {
            let difference = rowDifference(previous, row, current, row)
            if difference <= 6 {
                stickyRows += 1
            } else if stickyRows >= 12 {
                return stickyRows
            } else {
                break
            }
        }
        return stickyRows >= 12 ? stickyRows : 0
    }

    static func rowDifference(
        _ lhs: PreparedFrame,
        _ lhsRow: Int,
        _ rhs: PreparedFrame,
        _ rhsRow: Int
    ) -> Double {
        let width = lhs.width
        let sampleStride = max(1, width / 64)
        let lhsOffset = lhsRow * width
        let rhsOffset = rhsRow * width
        var total = 0
        var samples = 0
        for column in stride(from: 0, to: width, by: sampleStride) {
            total += abs(
                Int(lhs.grayscale[lhsOffset + column]) -
                Int(rhs.grayscale[rhsOffset + column])
            )
            samples += 1
        }
        return samples > 0 ? Double(total) / Double(samples) : .infinity
    }

    static func visionDisplacement(
        previous: CGImage,
        current: CGImage
    ) -> Int? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previous)
        let handler = VNImageRequestHandler(cgImage: current)

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let result = request.results?.first as? VNImageTranslationAlignmentObservation,
              result.confidence >= 0.65 else {
            return nil
        }

        let displacement = Int(result.alignmentTransform.ty.rounded())
        if displacement < -previous.height || displacement > previous.height {
            return nil
        }
        return displacement
    }
}
