import AppKit
import os.log

private let logger = Logger(subsystem: "com.caloura.app", category: "AppMover")

@MainActor
enum AppMover {

    private static let applicationsPath = "/Applications/"

    static var isInApplicationsFolder: Bool {
        Bundle.main.bundlePath.hasPrefix(applicationsPath)
    }

    /// Prompts to move the app to /Applications if not already there.
    /// Returns `true` if the app is relocating (caller should bail out of launch).
    @discardableResult
    static func moveToApplicationsFolderIfNeeded() -> Bool {
        guard !isInApplicationsFolder else { return false }

        let alert = NSAlert()
        alert.messageText = "Move to Applications?"
        alert.informativeText =
            "Caloura needs to live in /Applications to receive automatic updates. " +
            "Move it now?"
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            logger.info("User declined move to Applications")
            return false
        }

        return performMove()
    }

    // MARK: - Private

    private static func performMove() -> Bool {
        let source = Bundle.main.bundlePath
        let appName = (source as NSString).lastPathComponent
        let destination = applicationsPath + appName

        let fileManager = FileManager.default

        do {
            // Trash existing copy if present
            if fileManager.fileExists(atPath: destination) {
                let trashURL = URL(fileURLWithPath: destination)
                try fileManager.trashItem(at: trashURL, resultingItemURL: nil)
                logger.info("Trashed existing copy at /Applications")
            }

            try fileManager.copyItem(atPath: source, toPath: destination)
            logger.info("Copied app to /Applications")

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
