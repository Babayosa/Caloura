import AppKit
import QuartzCore

extension RegionSelectionView {
    func setupBackgroundLayer(in root: CALayer) {
        backgroundLayer.contentsGravity = .resizeAspectFill
        backgroundLayer.frame = bounds
        backgroundLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        root.addSublayer(backgroundLayer)
    }

    func setupDimmingLayer(in root: CALayer) {
        dimmingLayer.fillColor = NSColor.clear.cgColor
        dimmingLayer.fillRule = .evenOdd
        dimmingLayer.frame = bounds
        root.addSublayer(dimmingLayer)
    }

    func setupBorderLayer(in root: CALayer) {
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        borderLayer.isHidden = true
        root.addSublayer(borderLayer)
    }

    func setupSizeLabel(in root: CALayer) {
        sizeContainer.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        sizeContainer.cornerRadius = 4
        sizeContainer.isHidden = true
        root.addSublayer(sizeContainer)

        sizeTextLayer.font = sizeFont
        sizeTextLayer.fontSize = sizeFont.pointSize
        sizeTextLayer.foregroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        sizeTextLayer.alignmentMode = .center
        sizeTextLayer.truncationMode = .none
        sizeTextLayer.isWrapped = false
        sizeContainer.addSublayer(sizeTextLayer)
    }

    func setupHintLabel(in root: CALayer) {
        hintContainer.backgroundColor = NSColor.black.withAlphaComponent(0.50).cgColor
        hintContainer.cornerRadius = 8
        hintContainer.isHidden = false
        root.addSublayer(hintContainer)

        hintTextLayer.string = Self.hintText
        hintTextLayer.font = hintFont
        hintTextLayer.fontSize = hintFont.pointSize
        hintTextLayer.foregroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
        hintTextLayer.alignmentMode = .center
        hintTextLayer.truncationMode = .none
        hintTextLayer.isWrapped = false
        hintContainer.addSublayer(hintTextLayer)

        layoutHintLabel()
    }
}
