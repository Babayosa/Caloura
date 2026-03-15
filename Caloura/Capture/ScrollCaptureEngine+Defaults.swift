import AppKit
import CoreGraphics

// MARK: - Default Implementations

private enum ScrollGesturePhase: Int64 {
    case began = 1
    case changed = 2
    case ended = 4
}

struct DefaultViewportDetector: ScrollViewportDetecting, Sendable {
    private struct Candidate {
        let element: AXUIElement
        let frame: CGRect
        let role: String
        let verticalScrollBar: AXUIElement?
        let supportsValue: Bool
        let hitCount: Int
        let confidence: Double
    }

    func detectViewport(
        in region: CGRect,
        geometry: ScrollScreenGeometry
    ) -> ScrollViewportDetection {
        let fallbackRect = ScrollCaptureHelpers.pixelAlignedRect(
            region,
            scale: geometry.scale,
            within: geometry.localBounds
        )
        let systemWide = AXUIElementCreateSystemWide()
        let probeFractions: [CGFloat] = [0.2, 0.5, 0.8]
        var accumulators: [String: CandidateAccumulator] = [:]

        for yFraction in probeFractions {
            for xFraction in probeFractions {
                let localPoint = CGPoint(
                    x: region.minX + region.width * xFraction,
                    y: region.minY + region.height * yFraction
                )
                let globalX = geometry.frame.origin.x + localPoint.x
                let globalY = geometry.primaryScreenHeight - (geometry.frame.origin.y + localPoint.y)

                var elementRef: AXUIElement?
                let result = AXUIElementCopyElementAtPosition(
                    systemWide,
                    Float(globalX),
                    Float(globalY),
                    &elementRef
                )
                guard result == .success, let elementRef else { continue }

                walkAncestors(from: elementRef, region: region, geometry: geometry) { candidate in
                    let key = candidate.identifier
                    var accumulator = accumulators[key] ?? CandidateAccumulator(
                        identifier: key,
                        element: candidate.element,
                        frame: candidate.frame,
                        role: candidate.role,
                        verticalScrollBar: candidate.verticalScrollBar,
                        supportsValue: candidate.supportsValue,
                        hitCount: 0
                    )
                    accumulator.hitCount += 1
                    accumulators[key] = accumulator
                }
            }
        }

        let candidates = accumulators.values
            .compactMap { accumulator in
                scoreCandidate(accumulator, region: region)
            }
            .sorted { lhs, rhs in
                lhs.confidence > rhs.confidence
            }

        guard let best = candidates.first else {
            return ScrollViewportDetection(
                detectedViewport: nil,
                fallbackRect: fallbackRect,
                isAmbiguous: false
            )
        }

        let ambiguous = candidates.count > 1
            && best.confidence >= 0.55
            && candidates[1].confidence >= 0.55
            && abs(best.confidence - candidates[1].confidence) < 0.05

        guard best.confidence >= 0.55, !ambiguous else {
            return ScrollViewportDetection(
                detectedViewport: nil,
                fallbackRect: fallbackRect,
                isAmbiguous: ambiguous
            )
        }

        let aligned = ScrollCaptureHelpers.pixelAlignedRect(
            best.frame,
            scale: geometry.scale,
            within: geometry.localBounds
        )

        return ScrollViewportDetection(
            detectedViewport: ScrollCaptureViewport(
                captureRect: aligned,
                confidence: best.confidence,
                usedAutoDetectedViewport: true,
                scrollElement: AXElementHandle(element: best.element),
                verticalScrollBar: best.verticalScrollBar.map(AXElementHandle.init(element:))
            ),
            fallbackRect: fallbackRect,
            isAmbiguous: false
        )
    }

    private struct CandidateAccumulator {
        let identifier: String
        let element: AXUIElement
        let frame: CGRect
        let role: String
        let verticalScrollBar: AXUIElement?
        let supportsValue: Bool
        var hitCount: Int
    }

    private struct AncestorCandidate {
        let identifier: String
        let element: AXUIElement
        let frame: CGRect
        let role: String
        let verticalScrollBar: AXUIElement?
        let supportsValue: Bool
    }

    private func walkAncestors(
        from element: AXUIElement,
        region: CGRect,
        geometry: ScrollScreenGeometry,
        visit: (AncestorCandidate) -> Void
    ) {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let resolvedCurrent = current else { break }
            guard let frame = localFrame(for: resolvedCurrent, geometry: geometry) else {
                current = elementAttribute(resolvedCurrent, kAXParentAttribute)?.element
                continue
            }

            let role = (attribute(resolvedCurrent, kAXRoleAttribute) as? String) ?? ""
            let verticalScrollBar = elementAttribute(
                resolvedCurrent,
                kAXVerticalScrollBarAttribute
            )?.element
            let supportsValue = attribute(resolvedCurrent, kAXValueAttribute) != nil
            let intersection = frame.intersection(region)

            if !intersection.isNull && frame.width >= 40 && frame.height >= 40 {
                var pid: pid_t = 0
                AXUIElementGetPid(resolvedCurrent, &pid)
                let identifier = "\(pid)-\(CFHash(resolvedCurrent))"
                visit(
                    AncestorCandidate(
                        identifier: identifier,
                        element: resolvedCurrent,
                        frame: frame,
                        role: role,
                        verticalScrollBar: verticalScrollBar,
                        supportsValue: supportsValue
                    )
                )
            }

            current = elementAttribute(resolvedCurrent, kAXParentAttribute)?.element
        }
    }

    private func scoreCandidate(_ candidate: CandidateAccumulator, region: CGRect) -> Candidate? {
        let roleScore: Double
        switch candidate.role {
        case "AXWebArea":
            roleScore = 0.36
        case "AXScrollArea":
            roleScore = 0.34
        case "AXList":
            roleScore = 0.30
        case "AXOutline":
            roleScore = 0.28
        case "AXTable":
            roleScore = 0.28
        default:
            roleScore = 0.08
        }

        let selectionArea = max(1.0, region.width * region.height)
        let intersection = candidate.frame.intersection(region)
        let intersectionRatio = max(0, min(1, (intersection.width * intersection.height) / selectionArea))
        let coverageScore = min(0.25, Double(candidate.hitCount) / 9.0 * 0.25)
        let scrollScore = (candidate.verticalScrollBar != nil || candidate.supportsValue) ? 0.14 : 0
        let centerScore = candidate.frame.contains(CGPoint(x: region.midX, y: region.midY)) ? 0.05 : 0
        let containmentBonus: Double = candidate.frame.contains(region) ? 0.05 : 0
        let rawScore = roleScore + intersectionRatio * 0.25
            + coverageScore + scrollScore + centerScore + containmentBonus
        let confidence = min(1.0, rawScore)

        return Candidate(
            element: candidate.element,
            frame: candidate.frame,
            role: candidate.role,
            verticalScrollBar: candidate.verticalScrollBar,
            supportsValue: candidate.supportsValue,
            hitCount: candidate.hitCount,
            confidence: confidence
        )
    }

    private func attribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXElementHandle? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }
        return AXElementHandle(attributeValue: value)
    }

    private func localFrame(
        for element: AXUIElement,
        geometry: ScrollScreenGeometry
    ) -> CGRect? {
        guard let position = cgPointAttribute(element, kAXPositionAttribute),
              let size = cgSizeAttribute(element, kAXSizeAttribute) else {
            return nil
        }

        return convertGlobalTopLeftRectToLocal(
            CGRect(origin: position, size: size),
            geometry: geometry
        )
    }

    private func convertGlobalTopLeftRectToLocal(
        _ rect: CGRect,
        geometry: ScrollScreenGeometry
    ) -> CGRect {
        let localX = rect.origin.x - geometry.frame.origin.x
        let appKitY = geometry.primaryScreenHeight - (rect.origin.y + rect.height)
        let localY = appKitY - geometry.frame.origin.y
        return CGRect(x: localX, y: localY, width: rect.width, height: rect.height)
    }

    private func cgPointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let typedValue = AXValueHandle(attributeValue: value) else {
            return nil
        }
        return typedValue.cgPoint()
    }

    private func cgSizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let typedValue = AXValueHandle(attributeValue: value) else {
            return nil
        }
        return typedValue.cgSize()
    }
}

final class DefaultScrollDriver: ScrollDriving, @unchecked Sendable {
    private let stateLock = NSLock()
    private var hasStartedScroll = false

    func scroll(by pixels: Int) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(pixels),
            wheel2: 0,
            wheel3: 0
        ) else {
            return
        }

        stateLock.lock()
        let shouldMarkChanged = hasStartedScroll
        hasStartedScroll = true
        stateLock.unlock()

        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: shouldMarkChanged
                ? ScrollGesturePhase.changed.rawValue
                : ScrollGesturePhase.began.rawValue
        )
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    func finishGesture() {
        stateLock.lock()
        let hadStartedScroll = hasStartedScroll
        hasStartedScroll = false
        stateLock.unlock()

        guard hadStartedScroll,
              let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: 0,
                wheel2: 0,
                wheel3: 0
              ) else {
            return
        }

        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: ScrollGesturePhase.ended.rawValue)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }
}

struct DefaultScrollSettling: ScrollSettling, Sendable {
    private let initialDelayNanos: UInt64
    private let probeDelayNanos: UInt64
    private let maxProbes: Int

    init(
        initialDelayNanos: UInt64 = 120_000_000,
        probeDelayNanos: UInt64 = 40_000_000,
        maxProbes: Int = 6
    ) {
        self.initialDelayNanos = initialDelayNanos
        self.probeDelayNanos = probeDelayNanos
        self.maxProbes = maxProbes
    }

    func settle(
        request: ScrollSettleRequest,
        captureFrame: @escaping @Sendable (CGRect) async throws -> CGImage,
        displacementEstimator: any ScrollDisplacementEstimating
    ) async throws -> ScrollSettledFrame? {
        let startDelay = request.mode == .manual ? 80_000_000 : initialDelayNanos
        try await Task.sleep(nanoseconds: startDelay)

        var probes: [ScrollCaptureHelpers.PreparedFrame] = []
        var lastProbe: ScrollCaptureHelpers.PreparedFrame?

        for probeIndex in 0..<maxProbes {
            try Task.checkCancellation()
            let image = try await captureFrame(request.region)
            guard let prepared = autoreleasepool(invoking: {
                ScrollCaptureHelpers.prepareFrame(image)
            }) else {
                continue
            }

            if request.mode == .manual,
               probeIndex == 0,
               let previousAcceptedFrame = request.previousAcceptedFrame {
                let movement = displacementEstimator.estimate(
                    previous: previousAcceptedFrame,
                    current: prepared,
                    options: .manual(
                        expectedDisplacement: request.expectedDisplacement,
                        stickyHeaderHeight: request.stickyHeaderHeight,
                        unstableBands: []
                    )
                )
                if !movement.isMeaningful {
                    return nil
                }
            }

            probes.append(prepared)

            if let lastProbe {
                let stability = displacementEstimator.estimate(
                    previous: lastProbe,
                    current: prepared,
                    options: .probeStability()
                )
                let hashSimilarity = ScrollCaptureHelpers.hashSimilarity(lastProbe, prepared)
                if stability.absoluteDisplacement <= 1 && hashSimilarity >= 0.95 {
                    return ScrollSettledFrame(
                        preparedFrame: prepared,
                        unstableBands: ScrollCaptureHelpers.detectUnstableBands(probes: probes),
                        stabilized: true,
                        probeCount: probes.count
                    )
                }
            }

            lastProbe = prepared
            if probeIndex + 1 < maxProbes {
                try await Task.sleep(nanoseconds: probeDelayNanos)
            }
        }

        guard let lastProbe else { return nil }
        return ScrollSettledFrame(
            preparedFrame: lastProbe,
            unstableBands: ScrollCaptureHelpers.detectUnstableBands(probes: probes),
            stabilized: false,
            probeCount: probes.count
        )
    }
}

struct DefaultScrollDisplacementEstimator: ScrollDisplacementEstimating, Sendable {
    func estimate(
        previous: ScrollCaptureHelpers.PreparedFrame,
        current: ScrollCaptureHelpers.PreparedFrame,
        options: ScrollDisplacementOptions
    ) -> ScrollDisplacementEstimate {
        ScrollCaptureHelpers.estimateDisplacement(
            previous: previous,
            current: current,
            options: options
        )
    }
}

struct DefaultScrollStitcher: ScrollStitching, Sendable {
    func stitch(
        frames: [ScrollCaptureFrame],
        maxCanvasHeight: Int
    ) throws -> ScrollStitchResult {
        try ScrollCaptureHelpers.stitch(
            frames: frames,
            maxCanvasHeight: maxCanvasHeight
        )
    }
}
