import CoreGraphics
import Foundation

struct Beautifier {
    static func beautify(cgImage: CGImage, theme: BeautifyTheme) async -> CGImage {
        await Task.detached(priority: .userInitiated) {
            renderBeautified(cgImage: cgImage, theme: theme)
        }.value
    }

    private static func renderBeautified(cgImage: CGImage, theme: BeautifyTheme) -> CGImage {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let padding = theme.padding
        let canvasWidth = Int(imageWidth + padding * 2)
        let canvasHeight = Int(imageHeight + padding * 2)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: canvasWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return cgImage
        }

        // Draw gradient background
        drawGradient(in: context, theme: theme, width: canvasWidth, height: canvasHeight, colorSpace: colorSpace)

        // Draw screenshot with rounded corners and shadow
        let imageRect = CGRect(x: padding, y: padding, width: imageWidth, height: imageHeight)

        // Rounded rect path (shared by shadow and clip)
        let path = CGMutablePath()
        path.addRoundedRect(
            in: imageRect,
            cornerWidth: theme.cornerRadius,
            cornerHeight: theme.cornerRadius
        )

        // Shadow: fill the rounded rect shape with shadow enabled.
        // The shadow extends outward; the fill itself is covered by the image draw below.
        context.saveGState()
        let shadowColor = CGColor(
            red: 0, green: 0, blue: 0,
            alpha: theme.shadowOpacity
        )
        context.setShadow(
            offset: CGSize(width: theme.shadowOffset.width, height: -theme.shadowOffset.height),
            blur: theme.shadowRadius,
            color: shadowColor
        )
        context.addPath(path)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()

        // Clip to rounded rect and draw the image (no shadow needed here)
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(cgImage, in: imageRect)
        context.restoreGState()

        return context.makeImage() ?? cgImage
    }

    private static func drawGradient(
        in context: CGContext,
        theme: BeautifyTheme,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace
    ) {
        let colors = theme.gradientColors.map { $0.cgColor }
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors as CFArray,
            locations: nil
        ) else { return }

        let angleRad = theme.gradientAngle * .pi / 180.0
        let centerX = CGFloat(width) / 2
        let centerY = CGFloat(height) / 2
        let length = max(CGFloat(width), CGFloat(height))

        let startPoint = CGPoint(
            x: centerX - cos(angleRad) * length / 2,
            y: centerY - sin(angleRad) * length / 2
        )
        let endPoint = CGPoint(
            x: centerX + cos(angleRad) * length / 2,
            y: centerY + sin(angleRad) * length / 2
        )

        context.drawLinearGradient(
            gradient,
            start: startPoint,
            end: endPoint,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
}
