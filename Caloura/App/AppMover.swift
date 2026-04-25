import AppKit
import Darwin
import os.log

private let logger = Logger(subsystem: "com.caloura.app", category: "AppMover")

enum AppInstallState: Equatable {
    case inApplications
    case needsMoveToApplications
    case moving
    case moveFailed(String)

    var failureMessage: String? {
        if case .moveFailed(let message) = self {
            return message
        }
        return nil
    }
}

@MainActor
enum AppMover {

    static let applicationsPath = "/Applications/"

    /// Injection seam for the move pipeline. Production code uses `liveHooks`;
    /// tests substitute closures that record + simulate filesystem outcomes
    /// without touching disk or NSApplication.
    struct Hooks {
        var fileExists: (String) -> Bool
        var trash: (URL) throws -> URL?
        var copy: (String, String) throws -> Void
        var move: (URL, URL) throws -> Void
        var remove: (URL) throws -> Void
        var clearQuarantine: (URL) throws -> Void
        var bundleIdentity: (String) -> String?
        var launch: (URL) throws -> Void
        var terminate: () -> Void
    }

    static let liveHooks = Hooks(
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        trash: { url in
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
            return trashedURL as URL?
        },
        copy: { try FileManager.default.copyItem(atPath: $0, toPath: $1) },
        move: { try FileManager.default.moveItem(at: $0, to: $1) },
        remove: { try FileManager.default.removeItem(at: $0) },
        clearQuarantine: { try removeQuarantineAttribute(at: $0) },
        bundleIdentity: { bundleIdentity(at: $0) },
        launch: { url in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", url.path]
            try process.run()
        },
        terminate: { NSApplication.shared.terminate(nil) }
    )

    static var isInApplicationsFolder: Bool {
        Bundle.main.bundlePath.hasPrefix(applicationsPath)
    }

    static var currentInstallState: AppInstallState {
        installState(forBundlePath: Bundle.main.bundlePath)
    }

    static func installState(forBundlePath bundlePath: String) -> AppInstallState {
        bundlePath.hasPrefix(applicationsPath)
            ? .inApplications
            : .needsMoveToApplications
    }

    @discardableResult
    static func moveToApplicationsFolder() -> AppInstallState {
        moveToApplicationsFolder(
            source: Bundle.main.bundlePath,
            destinationURL: applicationsBundleURL(),
            hooks: liveHooks
        )
    }

    @discardableResult
    static func moveToApplicationsFolder(
        source: String,
        destinationURL: URL,
        hooks: Hooks
    ) -> AppInstallState {
        guard case .needsMoveToApplications = installState(forBundlePath: source) else {
            return .inApplications
        }

        if isAppTranslocated(source),
           hooks.fileExists(destinationURL.path),
           hooks.bundleIdentity(source) == hooks.bundleIdentity(destinationURL.path) {
            return relaunchInstalledCopy(destinationURL: destinationURL, hooks: hooks)
        }

        return performMove(
            source: source,
            destinationURL: destinationURL,
            hooks: hooks
        )
    }

    @discardableResult
    static func relaunchFromApplicationsIfAvailable() -> Bool {
        let destinationURL = applicationsBundleURL()
        guard FileManager.default.fileExists(atPath: destinationURL.path) else { return false }
        return relaunchInstalledCopy(destinationURL: destinationURL, hooks: liveHooks) == .moving
    }

    @discardableResult
    static func relaunchIfCurrentProcessIsTranslocatedInstall() -> Bool {
        guard isAppTranslocated(Bundle.main.bundlePath) else { return false }
        return relaunchFromApplicationsIfAvailable()
    }

    static func sourceBundlePath(bundle: Bundle = .main) -> String {
        bundle.bundlePath
    }

    /// Pure move pipeline. Internal access for unit tests; production callers
    /// must go through `moveToApplicationsFolder()`.
    static func performMove(
        source: String,
        destinationURL: URL,
        hooks: Hooks
    ) -> AppInstallState {
        let destination = destinationURL.path
        var trashedItemURL: URL?

        if hooks.fileExists(destination) {
            do {
                trashedItemURL = try hooks.trash(destinationURL)
                logger.info("Trashed existing copy at /Applications")
            } catch {
                let msg = "Failed to move to Applications: \(error.localizedDescription)"
                logger.error("\(msg, privacy: .public)")
                return .moveFailed(msg)
            }
        }

        do {
            try hooks.copy(source, destination)
        } catch let copyError {
            let restoreFailure = restoreTrashed(trashedItemURL, to: destinationURL, hooks: hooks)
            if let restoreFailure {
                let msg = "Failed to move to Applications: " +
                    "\(copyError.localizedDescription); " +
                    "rollback also failed: \(restoreFailure.localizedDescription)"
                logger.error("\(msg, privacy: .public)")
                return .moveFailed(msg)
            }
            let msg = "Failed to move to Applications: \(copyError.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            return .moveFailed(msg)
        }
        logger.info("Copied app to /Applications")

        let destInfoPlist = destination + "/Contents/Info.plist"
        let executableName = destinationURL.deletingPathExtension().lastPathComponent
        let destExecutable = destination + "/Contents/MacOS/" + executableName
        guard hooks.fileExists(destInfoPlist), hooks.fileExists(destExecutable) else {
            try? hooks.remove(destinationURL)
            let restoreFailure = restoreTrashed(trashedItemURL, to: destinationURL, hooks: hooks)
            if let restoreFailure {
                let msg = "Post-copy verification failed: destination bundle is incomplete; " +
                    "rollback also failed: \(restoreFailure.localizedDescription)"
                logger.error("\(msg, privacy: .public)")
                return .moveFailed(msg)
            }
            let msg = "Post-copy verification failed: destination bundle is incomplete"
            logger.error("\(msg, privacy: .public)")
            return .moveFailed(msg)
        }
        logger.info("Post-copy verification passed")

        return relaunchInstalledCopy(destinationURL: destinationURL, hooks: hooks)
    }

    private static func restoreTrashed(
        _ trashedURL: URL?,
        to destinationURL: URL,
        hooks: Hooks
    ) -> Error? {
        guard let trashedURL else { return nil }
        do {
            try hooks.move(trashedURL, destinationURL)
            logger.info("Restored previous copy from trash")
            return nil
        } catch {
            logger.error(
                "Failed to restore previous copy from trash: \(error.localizedDescription, privacy: .public)"
            )
            return error
        }
    }

    // MARK: - Private

    private static func applicationsBundleURL() -> URL {
        let appName = Bundle.main.bundleURL.lastPathComponent
        return URL(fileURLWithPath: applicationsPath).appendingPathComponent(appName)
    }

    private static func isAppTranslocated(_ bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    private static func relaunchInstalledCopy(destinationURL: URL, hooks: Hooks) -> AppInstallState {
        do {
            try hooks.clearQuarantine(destinationURL)
            try hooks.launch(destinationURL)
        } catch {
            let msg = "Failed to relaunch from Applications: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            return .moveFailed(msg)
        }
        hooks.terminate()
        return .moving
    }

    private static func removeQuarantineAttribute(at url: URL) throws {
        var firstError: Error?
        removeQuarantineAttributeFromItem(at: url, firstError: &firstError)

        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let childURL as URL in enumerator {
                removeQuarantineAttributeFromItem(at: childURL, firstError: &firstError)
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private static func removeQuarantineAttributeFromItem(at url: URL, firstError: inout Error?) {
        guard firstError == nil else { return }
        let result = removexattr(url.path, "com.apple.quarantine", 0)
        guard result != 0, errno != ENOATTR else { return }
        firstError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func bundleIdentity(at bundlePath: String) -> String? {
        let plistURL = URL(fileURLWithPath: bundlePath)
            .appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plistURL),
              let shortVersion = info["CFBundleShortVersionString"] as? String,
              let buildVersion = info["CFBundleVersion"] as? String else {
            return nil
        }
        return "\(shortVersion)|\(buildVersion)"
    }
}
