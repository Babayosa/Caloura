import CoreGraphics
import Foundation

extension ScrollCaptureHelpers {
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

        let candidateRange = displacementCandidateRange(
            previousHeight: previous.height,
            options: options
        )
        let bandMatch = bestBandMatch(
            previous: previous,
            current: current,
            candidateRange: candidateRange,
            options: options
        )

        if let bandMatch {
            let runnerUp = bandMatch.runnerUpError.isFinite
                ? bandMatch.runnerUpError
                : bandMatch.error + 1
            let margin = runnerUp > 0
                ? max(0, (runnerUp - bandMatch.error) / runnerUp)
                : 0
            let confidence = max(0, min(1, margin + max(0, 1 - bandMatch.error / 40)))
            if confidence >= 0.2 {
                return ScrollDisplacementEstimate(
                    displacement: bandMatch.displacement,
                    confidence: confidence,
                    winnerMargin: margin,
                    meanError: bandMatch.error,
                    method: .bandMatch
                )
            }
        }

        if let visionEstimate = visionFallbackEstimate(
            previous: previous,
            current: current,
            candidateRange: candidateRange,
            options: options,
            meanError: bandMatch?.error ?? .greatestFiniteMagnitude
        ) {
            return visionEstimate
        }

        return ScrollDisplacementEstimate(
            displacement: 0,
            confidence: 0,
            winnerMargin: 0,
            meanError: bandMatch?.error ?? .greatestFiniteMagnitude,
            method: .none
        )
    }

    private static func displacementCandidateRange(
        previousHeight: Int,
        options: ScrollDisplacementOptions
    ) -> ClosedRange<Int> {
        let maxDisplacement = max(
            1,
            min(previousHeight - 1, previousHeight - max(options.bottomExclusion, 1))
        )
        let center = options.expectedDisplacement ?? 0
        let lowerBound = options.allowNegativeDisplacement
            ? max(-maxDisplacement, center - options.allowedDelta)
            : 0
        let upperBound = min(maxDisplacement, center + options.allowedDelta)
        return lowerBound <= upperBound ? lowerBound...upperBound : 0...maxDisplacement
    }

    private static func bestBandMatch(
        previous: PreparedFrame,
        current: PreparedFrame,
        candidateRange: ClosedRange<Int>,
        options: ScrollDisplacementOptions
    ) -> DisplacementRefinement? {
        var bestDisplacement = 0
        var bestError = Double.greatestFiniteMagnitude
        var runnerUpError = Double.greatestFiniteMagnitude

        for displacement in candidateRange {
            let error = meanBandDifference(
                previous: previous,
                current: current,
                options: BandComparisonOptions(
                    displacement: displacement,
                    stickyHeaderHeight: options.stickyHeaderHeight,
                    bottomExclusion: options.bottomExclusion,
                    excludedBands: options.unstableBands
                )
            )

            guard error.isFinite else { continue }
            if error < bestError {
                runnerUpError = bestError
                bestError = error
                bestDisplacement = displacement
            } else if error < runnerUpError {
                runnerUpError = error
            }
        }

        guard bestError.isFinite else { return nil }
        return refineDisplacement(
            around: bestDisplacement,
            within: candidateRange,
            previous: previous,
            current: current,
            options: options
        )
    }

    private static func visionFallbackEstimate(
        previous: PreparedFrame,
        current: PreparedFrame,
        candidateRange: ClosedRange<Int>,
        options: ScrollDisplacementOptions,
        meanError: Double
    ) -> ScrollDisplacementEstimate? {
        guard let visionResult = visionDisplacement(
            previous: previous.image,
            current: current.image
        ),
        options.allowNegativeDisplacement || visionResult.displacement >= 0 else {
            return nil
        }

        let clampedDisplacement = min(
            candidateRange.upperBound,
            max(candidateRange.lowerBound, visionResult.displacement)
        )
        let confidence = max(0.55, Double(visionResult.confidence))
        return ScrollDisplacementEstimate(
            displacement: clampedDisplacement,
            confidence: confidence,
            winnerMargin: 0,
            meanError: meanError,
            method: .vision
        )
    }

    private static func refineDisplacement(
        around seedDisplacement: Int,
        within candidateRange: ClosedRange<Int>,
        previous: PreparedFrame,
        current: PreparedFrame,
        options: ScrollDisplacementOptions
    ) -> DisplacementRefinement {
        let lowerBound = max(candidateRange.lowerBound, seedDisplacement - 6)
        let upperBound = min(candidateRange.upperBound, seedDisplacement + 6)

        guard lowerBound <= upperBound else {
            return DisplacementRefinement(
                displacement: seedDisplacement,
                error: .infinity,
                runnerUpError: .infinity
            )
        }

        var bestDisplacement = seedDisplacement
        var bestError = Double.greatestFiniteMagnitude
        var runnerUpError = Double.greatestFiniteMagnitude

        for displacement in lowerBound...upperBound {
            let error = refinedOverlapDifference(
                previous: previous,
                current: current,
                displacement: displacement,
                options: options
            )

            guard error.isFinite else { continue }
            if error < bestError {
                runnerUpError = bestError
                bestError = error
                bestDisplacement = displacement
            } else if error < runnerUpError {
                runnerUpError = error
            }
        }

        return DisplacementRefinement(
            displacement: bestDisplacement,
            error: bestError,
            runnerUpError: runnerUpError
        )
    }

    private static func refinedOverlapDifference(
        previous: PreparedFrame,
        current: PreparedFrame,
        displacement: Int,
        options: ScrollDisplacementOptions
    ) -> Double {
        let width = previous.width
        let sampleStride = max(1, width / 96)
        let usableStart = max(0, options.stickyHeaderHeight)
        let usableEnd = previous.height - max(0, options.bottomExclusion)
        let overlapHeight = usableEnd - usableStart - abs(displacement)

        guard overlapHeight >= 8 else {
            return .infinity
        }

        let previousBaseRow: Int
        let currentBaseRow: Int
        if displacement >= 0 {
            previousBaseRow = usableStart + displacement
            currentBaseRow = usableStart
        } else {
            previousBaseRow = usableStart
            currentBaseRow = usableStart - displacement
        }

        var totalDifference = 0
        var samples = 0
        for rowOffset in 0..<overlapHeight {
            let previousRow = previousBaseRow + rowOffset
            let currentRow = currentBaseRow + rowOffset
            guard previousRow >= 0,
                  currentRow >= 0,
                  previousRow < previous.height,
                  currentRow < current.height else {
                continue
            }

            let bandIndex = bandIndexForRow(
                currentRow,
                height: current.height,
                topExclusion: options.stickyHeaderHeight,
                bottomExclusion: options.bottomExclusion
            )
            if let bandIndex, options.unstableBands.contains(bandIndex) {
                continue
            }

            let previousOffset = previousRow * width
            let currentOffset = currentRow * width
            for column in stride(from: 0, to: width, by: sampleStride) {
                totalDifference += abs(
                    Int(previous.grayscale[previousOffset + column]) -
                    Int(current.grayscale[currentOffset + column])
                )
                samples += 1
            }
        }

        return samples > 0 ? Double(totalDifference) / Double(samples) : .infinity
    }

    private static func bandIndexForRow(
        _ row: Int,
        height: Int,
        topExclusion: Int,
        bottomExclusion: Int
    ) -> Int? {
        let usableStart = max(0, topExclusion)
        let usableEnd = height - max(0, bottomExclusion)
        guard row >= usableStart, row < usableEnd else {
            return nil
        }

        let usableHeight = usableEnd - usableStart
        guard usableHeight > 0 else {
            return nil
        }

        return min(
            bandCount - 1,
            max(0, (row - usableStart) * bandCount / usableHeight)
        )
    }

    private static func meanBandDifference(
        previous: PreparedFrame,
        current: PreparedFrame,
        options: BandComparisonOptions
    ) -> Double {
        let maxSearchMagnitude = abs(options.displacement)
        let topExclusion = max(0, options.stickyHeaderHeight)
        let usableStart = topExclusion
        let usableHeight = previous.height - options.bottomExclusion - maxSearchMagnitude - usableStart
        guard usableHeight >= 8 else { return .infinity }

        let minimumBandHeight = max(4, previous.height / 40)
        let bandHeight = max(minimumBandHeight, min(24, usableHeight / 3))
        let effectiveBandCount = min(bandCount, max(1, usableHeight / max(1, bandHeight)))
        var totalError = 0.0
        var usedBands = 0

        for bandIndex in 0..<effectiveBandCount where !options.excludedBands.contains(bandIndex) {
            let maxBandOrigin = usableStart + usableHeight - bandHeight
            let bandOrigin = usableStart
                + (bandIndex * max(1, maxBandOrigin - usableStart)) / max(1, effectiveBandCount - 1)

            let comparisonOriginPrevious: Int
            let comparisonOriginCurrent: Int
            if options.displacement >= 0 {
                comparisonOriginPrevious = bandOrigin + options.displacement
                comparisonOriginCurrent = bandOrigin
            } else {
                comparisonOriginPrevious = bandOrigin
                comparisonOriginCurrent = bandOrigin - options.displacement
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
        let bandOrigin = usableStart
            + (clampedBandIndex * max(1, maxBandOrigin - usableStart)) / max(1, effectiveBandCount - 1)

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
                totalDifference += abs(
                    Int(previous.grayscale[previousRow + column]) -
                    Int(current.grayscale[currentRow + column])
                )
                samples += 1
            }
        }

        return samples > 0 ? Double(totalDifference) / Double(samples) : .infinity
    }
}
