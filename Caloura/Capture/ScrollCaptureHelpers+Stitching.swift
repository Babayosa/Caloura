import CoreGraphics
import Foundation

private struct RowCopyPlan {
    let sourceStartRow: Int
    let destinationStartRow: Int
    let rowCount: Int
}

extension ScrollCaptureHelpers {
    static func stitch(
        frames: [ScrollCaptureFrame],
        maxCanvasHeight: Int
    ) throws -> ScrollStitchResult {
        guard let first = frames.first else {
            throw ScrollCaptureError.noFramesCaptured
        }

        let totalHeight = min(
            maxCanvasHeight,
            frames.map(\.estimatedBottom).max() ?? first.height
        )
        let bytesPerRow = first.preparedFrame.bitmap.bytesPerRow
        let byteCount = totalHeight * bytesPerRow
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        pixels.initialize(repeating: 0, count: byteCount)
        var seamRepairCount = 0

        copyRows(
            from: first.preparedFrame.bitmap,
            into: pixels,
            bytesPerRow: bytesPerRow,
            plan: RowCopyPlan(
                sourceStartRow: 0,
                destinationStartRow: 0,
                rowCount: min(first.height, totalHeight)
            )
        )

        for index in 1..<frames.count {
            let previous = frames[index - 1]
            let current = frames[index]
            guard current.preparedFrame.bitmap.bytesPerRow == bytesPerRow else { continue }
            let seam = chooseSeam(previous: previous, current: current)
            if seam.expandedSearchUsed {
                seamRepairCount += 1
            }

            let startCanvasRow = max(0, seam.splitY)
            let endCanvasRow = min(totalHeight, current.estimatedBottom)
            guard endCanvasRow > startCanvasRow else { continue }

            let sourceStartRow = max(0, startCanvasRow - current.originY)
            copyRows(
                from: current.preparedFrame.bitmap,
                into: pixels,
                bytesPerRow: bytesPerRow,
                plan: RowCopyPlan(
                    sourceStartRow: sourceStartRow,
                    destinationStartRow: startCanvasRow,
                    rowCount: endCanvasRow - startCanvasRow
                )
            )
        }

        guard let image = makeImage(
            width: first.width,
            height: totalHeight,
            bytesPerRow: bytesPerRow,
            pixels: pixels,
            byteCount: byteCount
        ) else {
            pixels.deallocate()
            throw ScrollCaptureError.canvasCreationFailed
        }

        return ScrollStitchResult(image: image, seamRepairCount: seamRepairCount)
    }

    private struct SeamDecision {
        let splitY: Int
        let expandedSearchUsed: Bool
    }

    private static func chooseSeam(
        previous: ScrollCaptureFrame,
        current: ScrollCaptureFrame
    ) -> SeamDecision {
        let overlapStart = max(previous.originY, current.originY + current.stickyHeaderHeight)
        let overlapEnd = min(previous.estimatedBottom, current.estimatedBottom)
        guard overlapEnd > overlapStart else {
            return SeamDecision(
                splitY: max(previous.originY, current.originY),
                expandedSearchUsed: false
            )
        }

        let expectedSplit = max(overlapStart, current.originY + current.stickyHeaderHeight)
        let initialWindow = max(overlapStart, expectedSplit - 8)...min(overlapEnd - 1, expectedSplit + 8)
        let initialChoice = bestSplit(
            in: initialWindow,
            previous: previous,
            current: current
        )

        guard initialChoice.error > 12 else {
            return SeamDecision(splitY: initialChoice.row, expandedSearchUsed: false)
        }

        let expandedWindow = overlapStart...min(overlapEnd - 1, expectedSplit + 24)
        let repairedChoice = bestSplit(
            in: expandedWindow,
            previous: previous,
            current: current
        )
        return SeamDecision(splitY: repairedChoice.row, expandedSearchUsed: true)
    }

    private static func bestSplit(
        in range: ClosedRange<Int>,
        previous: ScrollCaptureFrame,
        current: ScrollCaptureFrame
    ) -> (row: Int, error: Double) {
        var bestRow = range.lowerBound
        var bestError = Double.greatestFiniteMagnitude

        for canvasRow in range {
            let previousRow = canvasRow - previous.originY
            let currentRow = canvasRow - current.originY
            guard previousRow >= 0,
                  currentRow >= 0,
                  previousRow < previous.height,
                  currentRow < current.height else {
                continue
            }

            let error = rowDifference(
                previous.preparedFrame,
                previousRow,
                current.preparedFrame,
                currentRow
            )
            if error < bestError {
                bestError = error
                bestRow = canvasRow
            }
        }

        return (bestRow, bestError)
    }

    private static func copyRows(
        from bitmap: BitmapData,
        into pixels: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int,
        plan: RowCopyPlan
    ) {
        guard plan.rowCount > 0 else { return }
        for rowOffset in 0..<plan.rowCount {
            let sourceOffset = (plan.sourceStartRow + rowOffset) * bitmap.bytesPerRow
            let destinationOffset = (plan.destinationStartRow + rowOffset) * bytesPerRow
            pixels.advanced(by: destinationOffset).update(
                from: bitmap.pointer.advanced(by: sourceOffset),
                count: bytesPerRow
            )
        }
    }

    private static func makeImage(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixels: UnsafeMutablePointer<UInt8>,
        byteCount: Int
    ) -> CGImage? {
        // Transfer ownership of the stitched canvas directly to Core Graphics.
        let data = Data(
            bytesNoCopy: UnsafeMutableRawPointer(pixels),
            count: byteCount,
            deallocator: .custom { pointer, _ in
                pointer.assumingMemoryBound(to: UInt8.self).deallocate()
            }
        )
        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
