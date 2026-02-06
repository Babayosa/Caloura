import AppKit

final class ProcessedScreenshot: @unchecked Sendable {
    let image: NSImage
    let cgImage: CGImage
    let context: CaptureContext
    let ocrText: String?

    private var _filePath: URL?
    var filePath: URL? {
        get {
            dataLock.lock()
            let value = _filePath
            dataLock.unlock()
            return value
        }
        set {
            dataLock.lock()
            _filePath = newValue
            dataLock.unlock()
        }
    }

    private var _fileName: String
    var fileName: String {
        get {
            dataLock.lock()
            let value = _fileName
            dataLock.unlock()
            return value
        }
        set {
            dataLock.lock()
            _fileName = newValue
            dataLock.unlock()
        }
    }

    private var _presetName: String?
    var presetName: String? {
        get {
            dataLock.lock()
            let value = _presetName
            dataLock.unlock()
            return value
        }
        set {
            dataLock.lock()
            _presetName = newValue
            dataLock.unlock()
        }
    }

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

        let data = (try? ImageProcessor.pngRepresentation(of: cgImage)) ?? Data()

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

        let data = (try? ImageProcessor.tiffRepresentation(of: cgImage)) ?? Data()

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
        self._filePath = filePath
        self._fileName = fileName
        self._presetName = presetName
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
