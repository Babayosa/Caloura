import AppKit
import Foundation

final class ProcessedScreenshot {
    let image: NSImage
    let cgImage: CGImage
    let context: CaptureContext
    let ocrText: String?
    var filePath: URL?
    var fileName: String
    var presetName: String?

    var width: Int { cgImage.width }
    var height: Int { cgImage.height }

    private let dataLock = NSLock()
    // Lazy-cached PNG representation (only computed when needed)
    private var _pngData: Data?
    func cachedPNGData() -> Data? {
        dataLock.lock()
        let data = _pngData
        dataLock.unlock()
        return data
    }
    var pngData: Data {
        dataLock.lock()
        if let cached = _pngData {
            dataLock.unlock()
            return cached
        }
        dataLock.unlock()

        let data = ImageProcessor.pngRepresentation(of: cgImage)

        dataLock.lock()
        _pngData = data
        dataLock.unlock()
        return data
    }

    // Lazy-cached TIFF representation (only computed when needed for clipboard)
    private var _tiffData: Data?
    func cachedTIFFData() -> Data? {
        dataLock.lock()
        let data = _tiffData
        dataLock.unlock()
        return data
    }
    var tiffData: Data {
        dataLock.lock()
        if let cached = _tiffData {
            dataLock.unlock()
            return cached
        }
        dataLock.unlock()

        let data = ImageProcessor.tiffRepresentation(of: cgImage)

        dataLock.lock()
        _tiffData = data
        dataLock.unlock()
        return data
    }

    init(
        image: NSImage,
        cgImage: CGImage,
        pngData: Data? = nil,
        context: CaptureContext,
        ocrText: String? = nil,
        filePath: URL? = nil,
        fileName: String = "",
        presetName: String? = nil
    ) {
        self.image = image
        self.cgImage = cgImage
        self._pngData = pngData
        self.context = context
        self.ocrText = ocrText
        self.filePath = filePath
        self.fileName = fileName
        self.presetName = presetName
    }

    func cachePNGData(_ data: Data) {
        dataLock.lock()
        if _pngData == nil {
            _pngData = data
        }
        dataLock.unlock()
    }

    func cacheTIFFData(_ data: Data) {
        dataLock.lock()
        if _tiffData == nil {
            _tiffData = data
        }
        dataLock.unlock()
    }

    func toScreenshotItem() -> ScreenshotItem {
        ScreenshotItem(
            filePath: filePath?.path ?? "",
            fileName: fileName,
            sourceAppName: context.sourceAppName,
            sourceWindowTitle: context.sourceWindowTitle,
            captureMode: context.mode.rawValue,
            presetName: presetName,
            ocrText: ocrText,
            width: width,
            height: height,
            title: context.sourceWindowTitle ?? context.sourceAppName ?? "Untitled",
            tags: []
        )
    }
}
