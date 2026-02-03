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
    // MARK: - Category Lookup (O(1) instead of O(n))

    private static let categoryMap: [String: AppCategory] = {
        var map = [String: AppCategory]()
        // Code editors
        for id in ["com.microsoft.vscode", "com.apple.dt.xcode", "com.jetbrains",
                   "com.sublimetext", "com.googlecode.iterm2", "com.apple.terminal",
                   "dev.warp.warp-stable"] {
            map[id] = .code
        }
        // Lecture/Video
        for id in ["us.zoom.xos", "com.microsoft.teams", "com.google.meet"] {
            map[id] = .lecture
        }
        // Browsers
        for id in ["com.apple.safari", "com.google.chrome", "org.mozilla.firefox",
                   "com.brave.browser", "com.microsoft.edgemac"] {
            map[id] = .web
        }
        // Chat
        for id in ["com.tinyspeck.slackmacgap", "com.hnc.discord",
                   "com.apple.mobilesms", "com.apple.messages"] {
            map[id] = .chat
        }
        // Documents
        for id in ["com.apple.pages", "com.apple.keynote", "com.microsoft.word",
                   "com.microsoft.powerpoint", "com.apple.preview"] {
            map[id] = .document
        }
        return map
    }()

    private static let lectureKeywords = ["lecture", "class", "lesson", "course", "seminar", "tutorial"]
    private static let lmsKeywords = ["canvas", "blackboard", "moodle", "coursera", "edx", "brightspace", "schoology"]

    /// Detect the current context based on the frontmost application.
    /// This is a fast, non-blocking call that uses cached app info.
    static func detectContext() -> (appName: String?, windowTitle: String?, category: AppCategory) {
        let workspace = NSWorkspace.shared
        guard let frontApp = workspace.frontmostApplication else {
            return (nil, nil, .other)
        }

        let appName = frontApp.localizedName
        let bundleID = frontApp.bundleIdentifier ?? ""

        // Skip window title lookup for speed - category is determined by bundle ID
        // Window title is only needed for lecture detection in browsers/video apps
        let category = fastCategorize(bundleID: bundleID)

        return (appName, nil, category)
    }

    /// Fast O(1) categorization using precomputed map
    private static func fastCategorize(bundleID: String) -> AppCategory {
        let bundleLower = bundleID.lowercased()

        // Direct lookup first
        if let category = categoryMap[bundleLower] {
            return category
        }

        // Prefix matching for JetBrains apps (com.jetbrains.*)
        for (key, category) in categoryMap {
            if bundleLower.hasPrefix(key) {
                return category
            }
        }

        return .other
    }

    /// Full categorization with window title (call async if needed)
    static func categorize(
        bundleID: String,
        appName: String?,
        windowTitle: String?
    ) -> AppCategory {
        let bundleLower = bundleID.lowercased()
        let titleLower = windowTitle?.lowercased() ?? ""

        // Fast path: direct lookup
        if let category = categoryMap[bundleLower] {
            // Special case: browsers might be showing lecture content
            if category == .web {
                if lmsKeywords.contains(where: { titleLower.contains($0) }) ||
                   lectureKeywords.contains(where: { titleLower.contains($0) }) {
                    return .lecture
                }
            }
            return category
        }

        // Prefix matching
        for (key, category) in categoryMap {
            if bundleLower.hasPrefix(key) {
                return category
            }
        }

        return .other
    }
}
