import AppKit
import Foundation

/// Handles incoming `snapnote://` URLs for automation integration.
///
/// Supported URL schemes:
/// ```
/// snapnote://capture/area?preset=lecture&then=copy,save
/// snapnote://capture/fullscreen?then=copy-markdown
/// snapnote://capture/window
/// snapnote://capture/repeat
/// snapnote://capture/delayed?seconds=3&mode=area
/// snapnote://copy/markdown
/// snapnote://copy/citation
/// snapnote://copy/ocr
/// snapnote://history
/// snapnote://settings
/// ```
@MainActor
struct URLSchemeHandler {

    /// Route an incoming URL to the appropriate action.
    static func handle(_ url: URL) {
        guard url.scheme == "snapnote" else { return }

        let host = url.host ?? ""
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
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        default:
            break
        }
    }

    // MARK: - Capture Routes

    private static func handleCapture(pathComponents: [String], params: [String: String]) {
        let mode = pathComponents.first ?? "area"

        // Apply preset if specified
        if let presetName = params["preset"] {
            let normalized = presetName.replacingOccurrences(of: "-", with: " ").capitalized
            if PresetManager.builtInPresetNames.contains(normalized) {
                AppSettings.shared.activePreset = normalized
            }
        }

        let pipeline = CapturePipeline.shared

        switch mode {
        case "area":
            pipeline.captureArea()
        case "fullscreen":
            pipeline.captureFullscreen()
        case "window":
            pipeline.captureWindow()
        case "repeat":
            pipeline.captureRepeat()
        case "delayed":
            let seconds = Int(params["seconds"] ?? "3") ?? 3
            let delayMode = captureModeFrom(params["mode"] ?? "area")
            pipeline.captureDelayed(seconds: seconds, mode: delayMode)
        default:
            break
        }

        // Handle post-capture actions via `then` parameter
        if let thenParam = params["then"] {
            let actions = thenParam.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            schedulePostCaptureActions(actions)
        }
    }

    // MARK: - Copy Routes

    private static func handleCopy(pathComponents: [String]) {
        let format = pathComponents.first ?? "markdown"
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
    private static func schedulePostCaptureActions(_ actions: [String]) {
        let nc = NotificationCenter.default
        // Use a class wrapper to allow mutation inside the closure
        final class TokenHolder: @unchecked Sendable {
            var token: NSObjectProtocol?
        }
        let holder = TokenHolder()
        holder.token = nc.addObserver(
            forName: .captureCompleted,
            object: nil,
            queue: .main
        ) { _ in
            if let token = holder.token {
                nc.removeObserver(token)
                holder.token = nil
            }
            Task { @MainActor in
                for action in actions {
                    switch action {
                    case "copy":
                        if let screenshot = AppState.shared.lastScreenshot {
                            ClipboardManager.copyImage(screenshot)
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
    }
}
