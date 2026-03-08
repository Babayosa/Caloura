import AppKit
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
        guard case .needsMoveToApplications = currentInstallState else {
            return .inApplications
        }
        return performMove()
    }

    @discardableResult
    static func relaunchFromApplicationsIfAvailable() -> Bool {
        let destinationURL = applicationsBundleURL()
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            return false
        }

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", destinationURL.path]
            try process.run()
            NSApplication.shared.terminate(nil)
            return true
        } catch {
            logger.error(
                "Failed to relaunch installed copy: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    static func sourceBundlePath(bundle: Bundle = .main) -> String {
        bundle.bundlePath
    }

    // MARK: - Private

    private static func applicationsBundleURL() -> URL {
        let appName = Bundle.main.bundleURL.lastPathComponent
        return URL(fileURLWithPath: applicationsPath).appendingPathComponent(appName)
    }

    private static func performMove() -> AppInstallState {
        let source = Bundle.main.bundlePath
        let fileManager = FileManager.default
        let destinationURL = applicationsBundleURL()
        let destination = destinationURL.path

        do {
            // Trash existing copy if present, keeping reference for rollback
            var trashedItemURL: NSURL?
            if fileManager.fileExists(atPath: destination) {
                try fileManager.trashItem(
                    at: destinationURL,
                    resultingItemURL: &trashedItemURL
                )
                logger.info("Trashed existing copy at /Applications")
            }

            do {
                try fileManager.copyItem(atPath: source, toPath: destination)
            } catch {
                // Restore previously trashed copy if the new copy failed (M16)
                if let trashedURL = trashedItemURL as URL? {
                    try? fileManager.moveItem(at: trashedURL, to: destinationURL)
                    logger.info("Restored previous copy from trash after copy failure")
                }
                throw error
            }
            logger.info("Copied app to /Applications")

            // Verify the copied bundle is intact
            let destInfoPlist = destination + "/Contents/Info.plist"
            let executableName = destinationURL
                .deletingPathExtension()
                .lastPathComponent
            let destExecutable = destination + "/Contents/MacOS/" + executableName
            guard fileManager.fileExists(atPath: destInfoPlist),
                  fileManager.fileExists(atPath: destExecutable) else {
                // Remove incomplete destination bundle (M15)
                try? fileManager.removeItem(at: destinationURL)
                let msg = "Post-copy verification failed: destination bundle is incomplete"
                logger.error("\(msg, privacy: .public)")
                return .moveFailed(msg)
            }
            logger.info("Post-copy verification passed")

            // Relaunch from new location
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", destinationURL.path]
            try process.run()

            // Terminate current instance
            NSApplication.shared.terminate(nil)
            return .moving
        } catch {
            let msg = "Failed to move to Applications: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            return .moveFailed(msg)
        }
    }
}
