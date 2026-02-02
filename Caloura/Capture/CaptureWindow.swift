import ScreenCaptureKit

/// Unified window type that works with both SCK and CG capture paths.
struct CaptureWindow: Identifiable {
    let id: CGWindowID
    let title: String
    let appName: String
    let frame: CGRect          // CG coordinates (top-left origin)
    let scWindow: SCWindow?    // nil when using CG path
}
