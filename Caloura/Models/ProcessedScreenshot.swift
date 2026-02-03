import AppKit
import Foundation

final class ProcessedScreenshot {
    let image: NSImage
    let cgImage: CGImage
    let pngData: Data
    let context: CaptureContext
    let ocrText: String?
    var filePath: URL?
    var fileName: String

    var width: Int { cgImage.width }
    var height: Int { cgImage.height }

    // Lazy-cached TIFF representation (only computed when needed for clipboard)
    private var _tiffData: Data?
    var tiffData: Data {
        if let cached = _tiffData {
            return cached
        }
        let data = ImageProcessor.tiffRepresentation(of: cgImage)
        _tiffData = data
        return data
    }

    init(
        image: NSImage,
        cgImage: CGImage,
        pngData: Data,
        context: CaptureContext,
        ocrText: String? = nil,
        filePath: URL? = nil,
        fileName: String = ""
    ) {
        self.image = image
        self.cgImage = cgImage
        self.pngData = pngData
        self.context = context
        self.ocrText = ocrText
        self.filePath = filePath
        self.fileName = fileName
    }

    func toScreenshotItem() -> ScreenshotItem {
        ScreenshotItem(
            filePath: filePath?.path ?? "",
            fileName: fileName,
            sourceAppName: context.sourceAppName,
            sourceWindowTitle: context.sourceWindowTitle,
            captureMode: context.mode.rawValue,
            ocrText: ocrText,
            width: width,
            height: height,
            title: context.sourceWindowTitle ?? context.sourceAppName ?? "Untitled",
            tags: []
        )
    }
}
