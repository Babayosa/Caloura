import AppKit
import Foundation

enum AppCategory: String, Codable {
    case code = "Code"
    case lecture = "Lecture"
    case web = "Web"
    case document = "Document"
    case chat = "Chat"
    case other = "Other"
}

struct ContextDetector {
    /// Detect the current context based on the frontmost application
    static func detectContext() -> (appName: String?, windowTitle: String?, category: AppCategory) {
        let workspace = NSWorkspace.shared
        guard let frontApp = workspace.frontmostApplication else {
            return (nil, nil, .other)
        }

        let appName = frontApp.localizedName
        let bundleID = frontApp.bundleIdentifier ?? ""
        let windowTitle = getWindowTitle(for: frontApp.processIdentifier)
        let category = categorize(bundleID: bundleID, appName: appName, windowTitle: windowTitle)

        return (appName, windowTitle, category)
    }

    /// Get the title of the frontmost window of a given process
    private static func getWindowTitle(for pid: pid_t) -> String? {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let windowPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID == pid,
                  let windowName = windowInfo[kCGWindowName as String] as? String,
                  !windowName.isEmpty else {
                continue
            }
            return windowName
        }
        return nil
    }

    /// Categorize the app based on bundle ID, name, and window title
    static func categorize(
        bundleID: String,
        appName: String?,
        windowTitle: String?
    ) -> AppCategory {
        let bundleLower = bundleID.lowercased()
        let titleLower = windowTitle?.lowercased() ?? ""

        // Code editors
        let codeApps = [
            "com.microsoft.vscode",
            "com.apple.dt.xcode",
            "com.jetbrains",
            "com.sublimetext",
            "com.googlecode.iterm2",
            "com.apple.terminal",
            "dev.warp.warp-stable"
        ]
        if codeApps.contains(where: { bundleLower.contains($0.lowercased()) }) {
            return .code
        }

        // Video conferencing (potential lectures)
        let lectureApps = ["us.zoom.xos", "com.microsoft.teams", "com.google.meet"]
        let lectureKeywords = ["lecture", "class", "lesson", "course", "seminar", "tutorial"]
        if lectureApps.contains(where: { bundleLower.contains($0.lowercased()) }) {
            if lectureKeywords.contains(where: { titleLower.contains($0) }) {
                return .lecture
            }
            return .lecture // Default video calls to lecture for students
        }

        // Browser - check for LMS in title
        let browserApps = ["com.apple.safari", "com.google.chrome", "org.mozilla.firefox", "com.brave.browser", "com.microsoft.edgemac"]
        let lmsKeywords = ["canvas", "blackboard", "moodle", "coursera", "edx", "brightspace", "schoology"]
        if browserApps.contains(where: { bundleLower.contains($0.lowercased()) }) {
            if lmsKeywords.contains(where: { titleLower.contains($0) }) || lectureKeywords.contains(where: { titleLower.contains($0) }) {
                return .lecture
            }
            return .web
        }

        // Chat apps
        let chatApps = ["com.tinyspeck.slackmacgap", "com.hnc.discord", "com.apple.mobilesms", "com.apple.messages"]
        if chatApps.contains(where: { bundleLower.contains($0.lowercased()) }) {
            return .chat
        }

        // Document apps
        let docApps = ["com.apple.pages", "com.apple.keynote", "com.microsoft.word", "com.microsoft.powerpoint", "com.apple.preview"]
        if docApps.contains(where: { bundleLower.contains($0.lowercased()) }) {
            return .document
        }

        return .other
    }
}
