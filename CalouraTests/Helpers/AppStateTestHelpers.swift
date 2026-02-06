@testable import Caloura

/// Shared test helpers for AppState tests.
enum AppStateTestHelpers {

    /// Creates a minimal `ScreenshotItem` for test use.
    static func makeItem(
        fileName: String,
        appName: String? = nil,
        ocrText: String? = nil,
        width: Int = 100,
        height: Int = 100
    ) -> ScreenshotItem {
        ScreenshotItem(
            filePath: "/tmp/\(fileName)",
            fileName: fileName,
            sourceAppName: appName,
            captureMode: "area",
            ocrText: ocrText,
            width: width,
            height: height
        )
    }
}
