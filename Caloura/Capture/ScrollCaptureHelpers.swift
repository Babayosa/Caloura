import CoreGraphics
import Foundation
import os.log
import Vision

private let helpersLogger = Logger(subsystem: "com.caloura.app", category: "ScrollCaptureHelpers")
// swiftlint:disable file_length type_body_length function_body_length function_parameter_count line_length

enum ScrollCaptureHelpers {
    static let bandCount = 8

    struct BitmapData {
        let pointer: UnsafePointer<UInt8>
        let data: CFData
        let bytesPerRow: Int
        let width: Int
        let height: Int

        var byteCount: Int {
            bytesPerRow * height
        }
    }

    struct PreparedFrame {
        let image: CGImage
        let bitmap: BitmapData
        let grayscale: [UInt8]
        let rowHashes: [UInt64]
        let coarseHash: UInt64

        var width: Int { bitmap.width }
        var height: Int { bitmap.height }
    }

    // MARK: - Frame Preparation

    static func renderToBitmap(_ image: CGImage) -> BitmapData? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = ctx.makeImage(),
              let data = rendered.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else {
            return nil
        }

        return BitmapData(
            pointer: pointer,
            data: data,
            bytesPerRow: bytesPerRow,
            width: width,
            height: height
        )
    }

    static func prepareFrame(_ image: CGImage) -> PreparedFrame? {
        guard let bitmap = renderToBitmap(image) else { return nil }
        let grayscale = makeGrayscale(bitmap)
        let rowHashes = makeRowHashes(grayscale: grayscale, width: bitmap.width, height: bitmap.height)
        let coarseHash = makeCoarseHash(rowHashes)
        return PreparedFrame(
            image: image,
            bitmap: bitmap,
            grayscale: grayscale,
            rowHashes: rowHashes,
            coarseHash: coarseHash
        )
    }

    private static func makeGrayscale(_ bitmap: BitmapData) -> [UInt8] {
        var grayscale = [UInt8](repeating: 0, count: bitmap.width * bitmap.height)
        let width = bitmap.width
        let height = bitmap.height

        for row in 0..<height {
            let sourceRow = row * bitmap.bytesPerRow
            let destinationRow = row * width
            for column in 0..<width {
                let sourceOffset = sourceRow + column * 4
                let red = Int(bitmap.pointer[sourceOffset])
                let green = Int(bitmap.pointer[sourceOffset + 1])
                let blue = Int(bitmap.pointer[sourceOffset + 2])
                grayscale[destinationRow + column] = UInt8((77 * red + 150 * green + 29 * blue) >> 8)
            }
        }

        return grayscale
    }

    private static func makeRowHashes(
        grayscale: [UInt8],
        width: Int,
        height: Int
    ) -> [UInt64] {
        let sampleStride = max(1, width / 64)
        return (0..<height).map { row in
            var hash: UInt64 = 14_695_981_039_346_656_037
            let offset = row * width
            for column in stride(from: 0, to: width, by: sampleStride) {
                hash ^= UInt64(grayscale[offset + column])
                hash &*= 1_099_511_628_211
            }
            return hash
        }
    }

    private static func makeCoarseHash(_ rowHashes: [UInt64]) -> UInt64 {
        let hashStride = max(1, rowHashes.count / 32)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for index in Swift.stride(from: 0, to: rowHashes.count, by: hashStride) {
            hash ^= rowHashes[index]
            hash &*= 0x1000_0000_01b3
        }
        return hash
    }

    // MARK: - Similarity / Band Instability

    static func pixelMatchRatio(_ bmpA: BitmapData, _ bmpB: BitmapData) -> Double {
        guard bmpA.width == bmpB.width && bmpA.height == bmpB.height else { return 0 }

        var sampledPixels = 0
        var matchingPixels = 0
        for row in stride(from: 0, to: bmpA.height, by: 3) {
            let offsetA = row * bmpA.bytesPerRow
            let offsetB = row * bmpB.bytesPerRow
            for column in stride(from: 0, to: bmpA.width, by: 4) {
                let pixelOffset = column * 4
                let red = abs(Int(bmpA.pointer[offsetA + pixelOffset]) - Int(bmpB.pointer[offsetB + pixelOffset]))
                let green = abs(Int(bmpA.pointer[offsetA + pixelOffset + 1]) - Int(bmpB.pointer[offsetB + pixelOffset + 1]))
                let blue = abs(Int(bmpA.pointer[offsetA + pixelOffset + 2]) - Int(bmpB.pointer[offsetB + pixelOffset + 2]))
                if red + green + blue < 10 {
                    matchingPixels += 1
                }
                sampledPixels += 1
            }
        }

        return sampledPixels > 0 ? Double(matchingPixels) / Double(sampledPixels) : 0
    }

    static func hashSimilarity(_ lhs: PreparedFrame, _ rhs: PreparedFrame) -> Double {
        guard lhs.rowHashes.count == rhs.rowHashes.count else { return 0 }
        let hashStride = max(1, lhs.rowHashes.count / 24)
        var matches = 0
        var samples = 0
        for index in Swift.stride(from: 0, to: lhs.rowHashes.count, by: hashStride) {
            if lhs.rowHashes[index] == rhs.rowHashes[index] {
                matches += 1
            }
            samples += 1
        }
        return samples > 0 ? Double(matches) / Double(samples) : 0
    }

    static func detectUnstableBands(probes: [PreparedFrame]) -> IndexSet {
        guard probes.count >= 2 else { return [] }

        var unstable = IndexSet()
        for band in 0..<bandCount {
            var pairChanges = 0
            var pairCount = 0
            for index in 1..<probes.count {
                let previous = probes[index - 1]
                let current = probes[index]
                pairCount += 1
                if meanBandDifference(
                    previous: previous,
                    current: current,
                    bandIndex: band,
                    topExclusion: 0,
                    bottomExclusion: 0
                ) > 18 {
                    pairChanges += 1
                }
            }

            if pairChanges * 2 >= pairCount {
                unstable.insert(band)
            }
        }

        return unstable
    }

    // MARK: - Displacement Estimation

    static func estimateDisplacement(
        previous: PreparedFrame,
        current: PreparedFrame,
        options: ScrollDisplacementOptions
    ) -> ScrollDisplacementEstimate {
        guard previous.width == current.width,
              previous.height == current.height else {
            return ScrollDisplacementEstimate(
                displacement: 0,
                confidence: 0,
                winnerMargin: 0,
                meanError: .infinity,
                method: .none
            )
        }

        let maxDisplacement = max(1, min(previous.height - 1, previous.height - max(options.bottomExclusion, 1)))
        let center = options.expectedDisplacement ?? 0
        let lowerBound = options.allowNegativeDisplacement
            ? max(-maxDisplacement, center - options.allowedDelta)
            : 0
        let upperBound = min(maxDisplacement, center + options.allowedDelta)

        let candidateRange: ClosedRange<Int>
        if lowerBound <= upperBound {
            candidateRange = lowerBound...upperBound
        } else {
            candidateRange = 0...maxDisplacement
        }

        var bestDisplacement = 0
        var bestError = Double.greatestFiniteMagnitude
        var runnerUpError = Double.greatestFiniteMagnitude

        for displacement in candidateRange {
            let bandError = meanBandDifference(
                previous: previous,
                current: current,
                displacement: displacement,
                stickyHeaderHeight: options.stickyHeaderHeight,
                bottomExclusion: options.bottomExclusion,
                excludedBands: options.unstableBands
            )

            guard bandError.isFinite else { continue }
            if bandError < bestError {
                runnerUpError = bestError
                bestError = bandError
                bestDisplacement = displacement
            } else if bandError < runnerUpError {
                runnerUpError = bandError
            }
        }

        if bestError.isFinite {
            let runnerUp = runnerUpError.isFinite ? runnerUpError : bestError + 1
            let margin = runnerUp > 0 ? max(0, (runnerUp - bestError) / runnerUp) : 0
            let confidence = max(0, min(1, margin + max(0, 1 - bestError / 40)))
            if confidence >= 0.2 {
                return ScrollDisplacementEstimate(
                    displacement: bestDisplacement,
                    confidence: confidence,
                    winnerMargin: margin,
                    meanError: bestError,
                    method: .bandMatch
                )
            }
        }

        if let visionDisplacement = visionDisplacement(previous: previous.image, current: current.image),
           options.allowNegativeDisplacement || visionDisplacement >= 0 {
            let clamped = min(upperBound, max(lowerBound, visionDisplacement))
            return ScrollDisplacementEstimate(
                displacement: clamped,
                confidence: 0.35,
                winnerMargin: 0,
                meanError: bestError,
                method: .vision
            )
        }

        return ScrollDisplacementEstimate(
            displacement: 0,
            confidence: 0,
            winnerMargin: 0,
            meanError: bestError,
            method: .none
        )
    }

    private static func meanBandDifference(
        previous: PreparedFrame,
        current: PreparedFrame,
        displacement: Int = 0,
        stickyHeaderHeight: Int,
        bottomExclusion: Int,
        excludedBands: IndexSet
    ) -> Double {
        let maxSearchMagnitude = abs(displacement)
        let topExclusion = max(0, stickyHeaderHeight)
        let usableStart = topExclusion
        let usableHeight = previous.height - bottomExclusion - maxSearchMagnitude - usableStart
        guard usableHeight >= 8 else { return .infinity }

        let minimumBandHeight = max(4, previous.height / 40)
        let bandHeight = max(minimumBandHeight, min(24, usableHeight / 3))
        let effectiveBandCount = min(bandCount, max(1, usableHeight / max(1, bandHeight)))
        var totalError = 0.0
        var usedBands = 0

        for bandIndex in 0..<effectiveBandCount where !excludedBands.contains(bandIndex) {
            let maxBandOrigin = usableStart + usableHeight - bandHeight
            let bandOrigin = usableStart + (bandIndex * max(1, maxBandOrigin - usableStart)) / max(1, effectiveBandCount - 1)

            let comparisonOriginPrevious: Int
            let comparisonOriginCurrent: Int
            if displacement >= 0 {
                comparisonOriginPrevious = bandOrigin + displacement
                comparisonOriginCurrent = bandOrigin
            } else {
                comparisonOriginPrevious = bandOrigin
                comparisonOriginCurrent = bandOrigin - displacement
            }

            guard comparisonOriginPrevious >= 0,
                  comparisonOriginCurrent >= 0,
                  comparisonOriginPrevious + bandHeight <= previous.height,
                  comparisonOriginCurrent + bandHeight <= current.height else {
                continue
            }

            totalError += bandDifference(
                previous: previous,
                previousStartRow: comparisonOriginPrevious,
                current: current,
                currentStartRow: comparisonOriginCurrent,
                height: bandHeight
            )
            usedBands += 1
        }

        return usedBands > 0 ? totalError / Double(usedBands) : .infinity
    }

    private static func meanBandDifference(
        previous: PreparedFrame,
        current: PreparedFrame,
        bandIndex: Int,
        topExclusion: Int,
        bottomExclusion: Int
    ) -> Double {
        meanBandDifferenceForSingleBand(
            previous: previous,
            current: current,
            bandIndex: bandIndex,
            topExclusion: topExclusion,
            bottomExclusion: bottomExclusion
        )
    }

    private static func meanBandDifferenceForSingleBand(
        previous: PreparedFrame,
        current: PreparedFrame,
        bandIndex: Int,
        topExclusion: Int,
        bottomExclusion: Int
    ) -> Double {
        let usableStart = max(0, topExclusion)
        let usableHeight = previous.height - bottomExclusion - usableStart
        guard usableHeight >= 8 else { return .infinity }

        let minimumBandHeight = max(4, previous.height / 40)
        let bandHeight = max(minimumBandHeight, min(24, usableHeight / 3))
        let effectiveBandCount = min(bandCount, max(1, usableHeight / max(1, bandHeight)))
        let maxBandOrigin = usableStart + usableHeight - bandHeight
        let clampedBandIndex = min(max(0, bandIndex), max(0, effectiveBandCount - 1))
        let bandOrigin = usableStart + (clampedBandIndex * max(1, maxBandOrigin - usableStart)) / max(1, effectiveBandCount - 1)
        return bandDifference(
            previous: previous,
            previousStartRow: bandOrigin,
            current: current,
            currentStartRow: bandOrigin,
            height: bandHeight
        )
    }

    private static func bandDifference(
        previous: PreparedFrame,
        previousStartRow: Int,
        current: PreparedFrame,
        currentStartRow: Int,
        height: Int
    ) -> Double {
        let width = previous.width
        let sampleStride = max(1, width / 64)
        var totalDifference = 0
        var samples = 0

        for rowOffset in 0..<height {
            let previousRow = (previousStartRow + rowOffset) * width
            let currentRow = (currentStartRow + rowOffset) * width
            for column in stride(from: 0, to: width, by: sampleStride) {
                totalDifference += abs(Int(previous.grayscale[previousRow + column]) - Int(current.grayscale[currentRow + column]))
                samples += 1
            }
        }

        return samples > 0 ? Double(totalDifference) / Double(samples) : .infinity
    }

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

    static func sharedTopRows(previous: PreparedFrame, current: PreparedFrame) -> Int {
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

    private static func rowDifference(
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
            total += abs(Int(lhs.grayscale[lhsOffset + column]) - Int(rhs.grayscale[rhsOffset + column]))
            samples += 1
        }
        return samples > 0 ? Double(total) / Double(samples) : .infinity
    }

    private static func visionDisplacement(previous: CGImage, current: CGImage) -> Int? {
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

    // MARK: - Stitching

    static func stitch(
        frames: [ScrollCaptureFrame],
        maxCanvasHeight: Int
    ) throws -> ScrollStitchResult {
        guard let first = frames.first else { throw ScrollCaptureError.noFramesCaptured }
        let totalHeight = min(maxCanvasHeight, frames.map(\.estimatedBottom).max() ?? first.height)
        let bytesPerRow = first.preparedFrame.bitmap.bytesPerRow
        var pixels = [UInt8](repeating: 0, count: totalHeight * bytesPerRow)
        var seamRepairCount = 0

        copyRows(
            from: first.preparedFrame.bitmap,
            sourceStartRow: 0,
            into: &pixels,
            destinationStartRow: 0,
            rowCount: min(first.height, totalHeight),
            bytesPerRow: bytesPerRow
        )

        for index in 1..<frames.count {
            let previous = frames[index - 1]
            let current = frames[index]
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
                sourceStartRow: sourceStartRow,
                into: &pixels,
                destinationStartRow: startCanvasRow,
                rowCount: endCanvasRow - startCanvasRow,
                bytesPerRow: bytesPerRow
            )
        }

        guard let image = makeImage(
            width: first.width,
            height: totalHeight,
            bytesPerRow: bytesPerRow,
            pixels: pixels
        ) else {
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
            return SeamDecision(splitY: max(previous.originY, current.originY), expandedSearchUsed: false)
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
        sourceStartRow: Int,
        into pixels: inout [UInt8],
        destinationStartRow: Int,
        rowCount: Int,
        bytesPerRow: Int
    ) {
        guard rowCount > 0 else { return }
        for rowOffset in 0..<rowCount {
            let sourceOffset = (sourceStartRow + rowOffset) * bitmap.bytesPerRow
            let destinationOffset = (destinationStartRow + rowOffset) * bytesPerRow
            pixels.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                baseAddress.advanced(by: destinationOffset).update(
                    from: bitmap.pointer.advanced(by: sourceOffset),
                    count: bytesPerRow
                )
            }
        }
    }

    private static func makeImage(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixels: [UInt8]
    ) -> CGImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Geometry

    static func pixelAlignedRect(
        _ rect: CGRect,
        scale: CGFloat,
        within bounds: CGRect
    ) -> CGRect {
        let clamped = rect.intersection(bounds)
        guard !clamped.isNull else { return .zero }

        let minX = floor(clamped.minX * scale) / scale
        let minY = floor(clamped.minY * scale) / scale
        let maxX = ceil(clamped.maxX * scale) / scale
        let maxY = ceil(clamped.maxY * scale) / scale

        let aligned = CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )

        return aligned.intersection(bounds)
    }
}
