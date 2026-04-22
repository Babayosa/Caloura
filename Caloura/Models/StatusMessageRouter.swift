import Foundation

/// Decouples Capture/ from `AppState`. Capture writes status messages to
/// the router; the App layer wires `sink` once at startup to forward into
/// `AppState.statusMessage`. Without this seam, every Capture/ file that
/// reports status would import `AppState`, leaking the global singleton
/// into a layer that should not know it exists.
@MainActor
enum StatusMessageRouter {
    static var sink: (String) -> Void = { _ in }
}
