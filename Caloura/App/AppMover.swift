import AppKit
import os.log

private let logger = Logger(subsystem: "com.caloura.app", category: "AppMover")

@MainActor
enum AppMover {

    private static let applicationsPath = "/Applications/"

    static var isInApplicationsFolder: Bool {
        Bundle.main.bundlePath.hasPrefix(applicationsPath)
    }

    private static let suppressionKey = "AppMover.suppressMovePrompt"

    /// Prompts to move the app to /Applications if not already there.
    /// Returns `true` if the app is relocating (caller should bail out of launch).
    @discardableResult
    static func moveToApplicationsFolderIfNeeded() -> Bool {
        guard !isInApplicationsFolder else { return false }
        guard !UserDefaults.standard.bool(forKey: suppressionKey) else { return false }

        let alert = NSAlert()
        alert.messageText = "Move to Applications?"
        alert.informativeText =
            "Caloura needs to live in /Applications to receive automatic updates. " +
            "Move it now?"
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")
        alert.alertStyle = .informational

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return performMove()
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: suppressionKey)
            logger.info("User suppressed move-to-Applications prompt")
            return false
        default:
            logger.info("User declined move to Applications")
            return false
        }
    }

    // MARK: - Private

    private static func performMove() -> Bool {
        let source = Bundle.main.bundlePath
        let appName = (source as NSString).lastPathComponent
        let destination = applicationsPath + appName

        let fileManager = FileManager.default

        let destinationURL = URL(fileURLWithPath: destination)

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
            let destExecutable = destination + "/Contents/MacOS/" + appName.replacingOccurrences(of: ".app", with: "")
            guard fileManager.fileExists(atPath: destInfoPlist),
                  fileManager.fileExists(atPath: destExecutable) else {
                // Remove incomplete destination bundle (M15)
                try? fileManager.removeItem(at: destinationURL)
                let msg = "Post-copy verification failed: destination bundle is incomplete"
                logger.error("\(msg, privacy: .public)")
                showError(NSError(domain: "AppMover", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: msg]))
                return false
            }
            logger.info("Post-copy verification passed")

            // Relaunch from new location
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", destination]
            try process.run()

            // Terminate current instance
            NSApplication.shared.terminate(nil)
            return true
        } catch {
            showError(error)
            return false
        }
    }

    private static func showError(_ error: Error) {
        let msg = "Failed to move to Applications: \(error.localizedDescription)"
        logger.error("\(msg, privacy: .public)")

        let alert = NSAlert()
        alert.messageText = "Move Failed"
        alert.informativeText = msg
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
