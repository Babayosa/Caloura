import AppKit
import os.log

/// Handles incoming `caloura://` URLs for automation integration.
///
/// Supported URL schemes:
/// ```
/// caloura://capture/area?preset=lecture&then=copy,save
/// caloura://capture/fullscreen?then=copy-markdown
/// caloura://capture/window
/// caloura://capture/repeat
/// caloura://capture/delayed?seconds=3&mode=area
/// caloura://copy/markdown?token=<authorization-token>
/// caloura://copy/citation?token=<authorization-token>
/// caloura://copy/ocr?token=<authorization-token>
/// caloura://history
/// caloura://settings
/// ```
///
/// Security: `caloura://copy/*` URLs and `capture/*?then=copy*,save`
/// post-capture actions can expose sensitive data. They require a
/// per-launch authorization token that is only available to in-process
/// callers (`URLSchemeHandler.currentCopyAuthorizationToken()`). External
/// applications cannot obtain this token, so polling-based attacks against
/// the OCR clipboard cache are rejected at the handler boundary.
@MainActor
struct URLSchemeHandler {
    @MainActor
    private final class PostCaptureActionObserver {
        let id = UUID()
        private let notificationCenter: NotificationCenter
        private let actions: [String]
        private let captureRequestID: UUID
        private var token: NSObjectProtocol?
        private var timeoutTask: Task<Void, Never>?

        init(
            actions: [String],
            captureRequestID: UUID,
            notificationCenter: NotificationCenter = .default
        ) {
            self.actions = actions
            self.captureRequestID = captureRequestID
            self.notificationCenter = notificationCenter
        }

        func start() {
            let observerID = id
            token = notificationCenter.addObserver(
                forName: .captureCompleted,
                object: nil,
                queue: .main
            ) { notification in
                guard notification.userInfo?[
                    AppNotificationUserInfoKey.captureRequestID
                ] as? UUID == self.captureRequestID else {
                    return
                }
                MainActor.assumeIsolated {
                    URLSchemeHandler.handlePostCaptureNotification(id: observerID)
                }
            }

            timeoutTask = Task { [observerID] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    URLSchemeHandler.cleanupPostCaptureObserver(id: observerID)
                }
            }
        }

        func runActionsAndCleanup() {
            cleanup()
            for action in actions {
                switch action {
                case "copy":
                    AppCommandRouter.shared.dispatch(.copyLastImage)
                case "copy-markdown":
                    AppCommandRouter.shared.dispatch(.copyLastAsMarkdown)
                case "copy-citation":
                    AppCommandRouter.shared.dispatch(.copyLastWithCitation)
                case "copy-ocr":
                    AppCommandRouter.shared.dispatch(.copyLastOCRText)
                case "save":
                    AppCommandRouter.shared.dispatch(.saveLastCapture)
                default:
                    let msg = "Unexpected post-capture action skipped: \(action)"
                    URLSchemeHandler.logger.warning("\(msg, privacy: .public)")
                }
            }
        }

        func cleanup() {
            if let token {
                notificationCenter.removeObserver(token)
                self.token = nil
            }
            timeoutTask?.cancel()
            timeoutTask = nil
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.caloura",
        category: "URLSchemeHandler"
    )
    private static var postCaptureObservers: [UUID: PostCaptureActionObserver] = [:]

    /// Minimum interval between accepted URL scheme requests (seconds).
    private static let throttleInterval: TimeInterval = 0.5

    /// Timestamp of the last successfully accepted request.
    private(set) static var lastHandledDate: Date?

    /// Per-launch authorization token gating `caloura://copy/*` URLs.
    /// Generated lazily on first access, never persisted, never logged.
    /// Rotates only on app relaunch.
    private static var copyAuthorizationToken: String = UUID().uuidString

    /// Token that in-process callers must include as `?token=…` on copy URLs.
    /// External processes cannot read this value, so they cannot construct a
    /// valid `caloura://copy/*` URL.
    static func currentCopyAuthorizationToken() -> String {
        copyAuthorizationToken
    }

    /// Allowed capture modes for the main mode switch.
    private static let allowedCaptureModes: Set<String> = [
        "area", "fullscreen", "window", "repeat", "delayed"
    ]

    /// Allowed modes for the delayed capture `mode` parameter.
    private static let allowedDelayModes: Set<String> = [
        "area", "fullscreen", "window"
    ]

    /// Allowed post-capture actions for the `then` parameter.
    private static let allowedPostCaptureActions: Set<String> = [
        "copy", "copy-markdown", "copy-citation", "copy-ocr", "save"
    ]

    // MARK: - Parsed Request (testable)

    enum ParsedAction: Equatable {
        case capture(mode: String, preset: String?, delay: Int?, delayMode: String?, thenActions: [String])
        case copy(format: String)
        case showHistory
        case showSettings
    }

    static func parse(_ url: URL) -> ParsedAction? {
        guard url.scheme == "caloura" else { return nil }
        let host = (url.host ?? "").lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let params = queryParameters(from: url)

        switch host {
        case "capture":
            let mode = (pathComponents.first ?? "area").lowercased()
            guard allowedCaptureModes.contains(mode) else { return nil }
            let preset: String? = {
                guard let raw = params["preset"] else { return nil }
                let normalized = raw.replacingOccurrences(of: "-", with: " ").capitalized
                return PresetManager.builtInPresetNames.contains(normalized) ? normalized : nil
            }()
            var delay: Int?
            var delayMode: String?
            if mode == "delayed" {
                delay = max(1, min(10, Int(params["seconds"] ?? "3") ?? 3))
                let raw = (params["mode"] ?? "area").lowercased()
                delayMode = allowedDelayModes.contains(raw) ? raw : "area"
            }
            let thenActions: [String] = params["then"].map { filterPostCaptureActions($0) } ?? []
            return .capture(mode: mode, preset: preset, delay: delay, delayMode: delayMode, thenActions: thenActions)
        case "copy":
            let format = (pathComponents.first ?? "markdown").lowercased()
            return .copy(format: format)
        case "history":
            return .showHistory
        case "settings":
            return .showSettings
        default:
            return nil
        }
    }

    /// Route an incoming URL to the appropriate action.
    static func handle(_ url: URL) {
        guard url.scheme == "caloura" else { return }

        // Rate-limit: reject requests arriving faster than throttleInterval.
        let now = Date()
        if let last = lastHandledDate,
           now.timeIntervalSince(last) < throttleInterval {
            logger.warning("URL scheme request throttled (too frequent)")
            return
        }
        lastHandledDate = now

        let host = (url.host ?? "").lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let params = queryParameters(from: url)

        switch host {
        case "capture":
            handleCapture(pathComponents: pathComponents, params: params)
        case "copy":
            handleCopy(pathComponents: pathComponents, params: params)
        case "history":
            AppCommandRouter.shared.dispatch(.showHistory)
        case "settings":
            AppCommandRouter.shared.dispatch(.showSettings)
        default:
            break
        }
    }

    // MARK: - Capture Routes

    private static func handleCapture(
        pathComponents: [String],
        params: [String: String]
    ) {
        let mode = (pathComponents.first ?? "area").lowercased()

        guard allowedCaptureModes.contains(mode) else {
            let msg = "Unknown capture mode ignored: \(mode)"
            logger.warning("\(msg, privacy: .public)")
            return
        }

        let validActions = authorizedPostCaptureActions(params: params)
        guard !AppState.shared.isCapturing else {
            logger.warning("capture_url_rejected reason=capture_already_active")
            return
        }

        applyPresetIfSpecified(params: params)
        let captureInitiated = dispatchCapture(mode: mode, params: params)

        if captureInitiated,
           AppState.shared.isCapturing,
           let captureRequestID = AppState.shared.currentCaptureRequestID,
           !validActions.isEmpty {
            schedulePostCaptureActions(validActions, captureRequestID: captureRequestID)
        }
    }

    private static func applyPresetIfSpecified(params: [String: String]) {
        guard let presetName = params["preset"] else { return }
        let normalized = presetName.replacingOccurrences(of: "-", with: " ").capitalized
        if PresetManager.builtInPresetNames.contains(normalized) {
            AppSettings.shared.activePreset = normalized
        }
    }

    private static func dispatchCapture(
        mode: String,
        params: [String: String]
    ) -> Bool {
        switch mode {
        case "area":
            AppCommandRouter.shared.dispatch(.captureArea)
        case "fullscreen":
            AppCommandRouter.shared.dispatch(.captureFullscreen)
        case "window":
            AppCommandRouter.shared.dispatch(.captureWindow)
        case "repeat":
            AppCommandRouter.shared.dispatch(.captureRepeat)
        case "delayed":
            let seconds = max(1, min(10, Int(params["seconds"] ?? "3") ?? 3))
            let delayMode = validatedDelayMode(from: params)
            AppCommandRouter.shared.dispatch(
                .captureDelayed(mode: delayMode, seconds: seconds)
            )
        default:
            return false
        }
        return true
    }

    private static func validatedDelayMode(
        from params: [String: String]
    ) -> CaptureMode {
        let raw = (params["mode"] ?? "area").lowercased()
        if allowedDelayModes.contains(raw) {
            return captureModeFrom(raw)
        }
        let msg = "Unknown delay mode '\(raw)', defaulting to area"
        logger.warning("\(msg, privacy: .public)")
        return .area
    }

    private static func filterPostCaptureActions(_ thenParam: String) -> [String] {
        thenParam.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { action in
                if allowedPostCaptureActions.contains(action) {
                    return true
                }
                let msg = "Unknown post-capture action ignored: \(action)"
                logger.warning("\(msg, privacy: .public)")
                return false
            }
    }

    private static func authorizedPostCaptureActions(params: [String: String]) -> [String] {
        guard let thenParam = params["then"] else { return [] }
        let token = params["token"] ?? ""
        guard !token.isEmpty,
              constantTimeEquals(token, copyAuthorizationToken) else {
            logger.warning("post_capture_actions_rejected reason=missing_or_invalid_token")
            return []
        }
        return filterPostCaptureActions(thenParam)
    }

    // MARK: - Copy Routes

    private static func handleCopy(pathComponents: [String], params: [String: String]) {
        // Reject any external `caloura://copy/*` invocation that lacks the
        // per-launch token. The token is unguessable and unavailable to
        // external processes, so this neutralizes the polling-attack vector
        // (background app spamming `caloura://copy/ocr` to drain history).
        let token = params["token"] ?? ""
        guard !token.isEmpty,
              constantTimeEquals(token, copyAuthorizationToken) else {
            logger.warning("copy_url_rejected reason=missing_or_invalid_token")
            return
        }

        let format = (pathComponents.first ?? "markdown").lowercased()

        switch format {
        case "image":
            AppCommandRouter.shared.dispatch(.copyLastImage)
        case "markdown":
            AppCommandRouter.shared.dispatch(.copyLastAsMarkdown)
        case "citation":
            AppCommandRouter.shared.dispatch(.copyLastWithCitation)
        case "ocr":
            AppCommandRouter.shared.dispatch(.copyLastOCRText)
        default:
            break
        }
    }

    /// Length-then-byte comparison without short-circuit. Both sides are
    /// in-process strings here, but a constant-time check keeps the code
    /// honest for any future reuse.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<lhsBytes.count {
            diff |= lhsBytes[index] ^ rhsBytes[index]
        }
        return diff == 0
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
    private static func schedulePostCaptureActions(_ actions: [String], captureRequestID: UUID) {
        let observer = PostCaptureActionObserver(
            actions: actions,
            captureRequestID: captureRequestID
        )
        postCaptureObservers[observer.id] = observer
        observer.start()
    }

    private static func handlePostCaptureNotification(id: UUID) {
        guard let observer = postCaptureObservers.removeValue(forKey: id) else {
            return
        }
        observer.runActionsAndCleanup()
    }

    private static func cleanupPostCaptureObserver(id: UUID) {
        guard let observer = postCaptureObservers.removeValue(forKey: id) else {
            return
        }
        observer.cleanup()
    }

    #if DEBUG
    static func resetThrottleForTesting() {
        lastHandledDate = nil
    }

    static func setLastHandledDateForTesting(_ date: Date?) {
        lastHandledDate = date
    }
    #endif
}
