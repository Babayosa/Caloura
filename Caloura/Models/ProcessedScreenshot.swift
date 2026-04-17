import AppKit

enum ProcessedScreenshotEncodingError: LocalizedError {
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .pngEncodingFailed:
            return "Failed to encode screenshot as PNG."
        }
    }
}

final class ProcessedScreenshot: @unchecked Sendable {
    let id: UUID
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
    func pngData() throws -> Data {
        dataLock.lock()
        defer { dataLock.unlock() }
        if let cached = _pngData {
            return cached
        }
        guard let data = try? ImageProcessor.pngRepresentation(of: cgImage) else {
            throw ProcessedScreenshotEncodingError.pngEncodingFailed
        }
        _pngData = data
        return data
    }

    /// Drop the lazy PNG buffer once distribution (clipboard + disk save)
    /// has completed. A 5K capture's PNG cache is 4-8 MB; on long-running
    /// sessions this reclaims 60-90 MB across the recent-capture window.
    /// `image`/`cgImage` are NOT released — beautify, preview, and
    /// thumbnailing still read them.
    func releaseEncodedCaches() {
        dataLock.lock()
        _pngData = nil
        dataLock.unlock()
    }

    init(
        id: UUID = UUID(),
        image: NSImage,
        cgImage: CGImage,
        pngData: Data? = nil,
        context: CaptureContext,
        ocrText: String? = nil,
        filePath: URL? = nil,
        fileName: String = "",
        presetName: String? = nil
    ) {
        self.id = id
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
            id: id,
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

    func replacingImage(
        _ newCGImage: CGImage,
        nsImage: NSImage? = nil,
        filePath: URL? = nil,
        fileName: String? = nil
    ) -> ProcessedScreenshot {
        let resolvedImage = nsImage ?? NSImage(
            cgImage: newCGImage,
            size: NSSize(width: newCGImage.width, height: newCGImage.height)
        )
        return ProcessedScreenshot(
            id: id,
            image: resolvedImage,
            cgImage: newCGImage,
            context: context,
            ocrText: ocrText,
            filePath: filePath ?? self.filePath,
            fileName: fileName ?? self.fileName,
            presetName: presetName
        )
    }
}
