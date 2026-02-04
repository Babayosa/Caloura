import AppKit
import Foundation

/// Handles incoming `caloura://` URLs for automation integration.
///
/// Supported URL schemes:
/// ```
/// caloura://capture/area?preset=lecture&then=copy,save
/// caloura://capture/fullscreen?then=copy-markdown
/// caloura://capture/window
/// caloura://capture/repeat
/// caloura://capture/delayed?seconds=3&mode=area
/// caloura://copy/markdown
/// caloura://copy/citation
/// caloura://copy/ocr
/// caloura://history
/// caloura://settings
/// ```
@MainActor
struct URLSchemeHandler {

    /// Route an incoming URL to the appropriate action.
    static func handle(_ url: URL) {
        guard url.scheme == "caloura" else { return }

        let host = (url.host ?? "").lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let params = queryParameters(from: url)

        switch host {
        case "capture":
            handleCapture(pathComponents: pathComponents, params: params)
        case "copy":
            handleCopy(pathComponents: pathComponents)
        case "history":
            NotificationCenter.default.post(name: .showHistory, object: nil)
        case "settings":
            NotificationCenter.default.post(name: .showSettings, object: nil)
        default:
            break
        }
    }

    // MARK: - Capture Routes

    private static func handleCapture(pathComponents: [String], params: [String: String]) {
        let mode = (pathComponents.first ?? "area").lowercased()

        // Apply preset if specified
        if let presetName = params["preset"] {
            let normalized = presetName.replacingOccurrences(of: "-", with: " ").capitalized
            if PresetManager.builtInPresetNames.contains(normalized) {
                AppSettings.shared.activePreset = normalized
            }
        }

        let pipeline = CapturePipeline.shared
        var captureInitiated = false

        switch mode {
        case "area":
            pipeline.captureArea()
            captureInitiated = true
        case "fullscreen":
            pipeline.captureFullscreen()
            captureInitiated = true
        case "window":
            pipeline.captureWindow()
            captureInitiated = true
        case "repeat":
            pipeline.captureRepeat()
            captureInitiated = true
        case "delayed":
            let seconds = Int(params["seconds"] ?? "3") ?? 3
            let delayMode = captureModeFrom(params["mode"] ?? "area")
            pipeline.captureDelayed(seconds: seconds, mode: delayMode)
            captureInitiated = true
        default:
            break
        }

        // Only register post-capture observer if a capture was actually initiated
        if captureInitiated, let thenParam = params["then"] {
            let actions = thenParam.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            if !actions.isEmpty {
                schedulePostCaptureActions(actions)
            }
        }
    }

    // MARK: - Copy Routes

    private static func handleCopy(pathComponents: [String]) {
        let format = (pathComponents.first ?? "markdown").lowercased()
        let pipeline = CapturePipeline.shared

        switch format {
        case "markdown":
            pipeline.copyLastAsMarkdown()
        case "citation":
            pipeline.copyLastWithCitation()
        case "ocr":
            pipeline.copyLastOCRText()
        default:
            break
        }
    }

    // MARK: - Helpers

    private static func queryParameters(from url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return [:]
        }
        var params: [String: String] = [:]
        for item in queryItems {
            params[item.name] = item.value ?? ""
        }
        return params
    }

    private static func captureModeFrom(_ string: String) -> CaptureMode {
        switch string.lowercased() {
        case "fullscreen": return .fullscreen
        case "window": return .window
        default: return .area
        }
    }

    /// Schedule post-capture actions to run after the capture completes.
    /// The observer auto-removes after firing or after a 30-second timeout.
    private static func schedulePostCaptureActions(_ actions: [String]) {
        let nc = NotificationCenter.default

        final class TokenHolder: @unchecked Sendable {
            var token: NSObjectProtocol?
            var timeoutWork: DispatchWorkItem?
        }
        let holder = TokenHolder()

        let cleanup: () -> Void = {
            if let token = holder.token {
                nc.removeObserver(token)
                holder.token = nil
            }
            holder.timeoutWork?.cancel()
            holder.timeoutWork = nil
        }

        holder.token = nc.addObserver(
            forName: .captureCompleted,
            object: nil,
            queue: .main
        ) { _ in
            cleanup()
            Task { @MainActor in
                for action in actions {
                    switch action {
                    case "copy":
                        if let screenshot = AppState.shared.lastScreenshot {
                            await ClipboardManager.copyImage(screenshot)
                        }
                    case "copy-markdown":
                        CapturePipeline.shared.copyLastAsMarkdown()
                    case "copy-citation":
                        CapturePipeline.shared.copyLastWithCitation()
                    case "copy-ocr":
                        CapturePipeline.shared.copyLastOCRText()
                    case "save":
                        break // Already handled by pipeline if autoSaveToDisk is on
                    default:
                        break
                    }
                }
            }
        }

        // Timeout: remove the observer after 30 seconds to prevent leaks
        // if the capture is cancelled or fails.
        let timeoutWork = DispatchWorkItem { cleanup() }
        holder.timeoutWork = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeoutWork)
    }
}
