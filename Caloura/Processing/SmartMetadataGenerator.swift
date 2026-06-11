import Foundation
import FoundationModels
import os.log

struct ScreenshotMetadata {
    let smartFileName: String?
    let summary: String?
    let tags: [String]
}

protocol MetadataGenerating {
    func generate(ocrText: String, sourceApp: String?, windowTitle: String?) async -> ScreenshotMetadata?
}

/// `LanguageModelSession` is not thread-safe; hoisting to an actor-isolated
/// singleton lets us persist one session across captures instead of spinning
/// up a fresh session per call (~80-120ms warmup).
private actor SharedLanguageModelSession {
    static let shared = SharedLanguageModelSession()
    private let session = LanguageModelSession()

    func respond(to prompt: String) async throws -> String {
        try await session.respond(to: prompt).content
    }
}

struct SmartMetadataGenerator: MetadataGenerating {
    static let shared = SmartMetadataGenerator()
    private static let logger = Logger(
        subsystem: "com.caloura.app",
        category: "SmartMetadata"
    )

    func generate(ocrText: String, sourceApp: String?, windowTitle: String?) async -> ScreenshotMetadata? {
        // FoundationModels' LanguageModelSession crashes intermittently
        // (EXC_BREAKPOINT in model-catalog XPC) inside unsigned XCTest hosts
        // and took the whole suite down with it. Metadata enrichment is
        // best-effort by contract (nil on timeout/failure); a test host never
        // gets a live session.
        if TestEnvironment.isHostingXCTest { return nil }

        let trimmedOCR = String(ocrText.prefix(1000))
        guard !trimmedOCR.isEmpty else { return nil }

        let appContext = sourceApp.map { "from \($0)" } ?? ""
        let windowContext = windowTitle.map { "window: \($0)" } ?? ""
        let contextLine = [appContext, windowContext].filter { !$0.isEmpty }.joined(separator: ", ")

        let prompt = """
        Analyze this screenshot text and provide:
        1. FILENAME: A concise descriptive filename (max 50 chars, lowercase, hyphens for spaces, no extension)
        2. SUMMARY: One sentence describing what this screenshot shows
        3. TAGS: 3-5 short topic tags, comma-separated

        Context: \(contextLine)
        Screenshot text:
        \(trimmedOCR)

        Respond in exactly this format:
        FILENAME: <filename>
        SUMMARY: <summary>
        TAGS: <tag1>, <tag2>, <tag3>
        """

        let response: String?
        do {
            response = try await withTimeout(seconds: 2) {
                try await SharedLanguageModelSession.shared.respond(to: prompt)
            }
        } catch TimeoutError.timedOut {
            Self.logger.debug("Metadata generation timed out")
            return nil
        } catch {
            Self.logger.debug("Metadata generation failed: \(error.localizedDescription)")
            return nil
        }

        guard let response else { return nil }
        return parseResponse(response)
    }

    func parseResponse(_ text: String) -> ScreenshotMetadata? {
        let lines = text.components(separatedBy: "\n")

        var fileName: String?
        var summary: String?
        var tags: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("FILENAME:") {
                let raw = trimmed.dropFirst("FILENAME:".count).trimmingCharacters(in: .whitespaces)
                let sanitized = FileOrganizer.sanitizeFileName(raw)
                if sanitized != "Unknown" {
                    fileName = sanitized
                }
            } else if trimmed.hasPrefix("SUMMARY:") {
                let raw = trimmed.dropFirst("SUMMARY:".count).trimmingCharacters(in: .whitespaces)
                if !raw.isEmpty {
                    summary = String(raw.prefix(200))
                }
            } else if trimmed.hasPrefix("TAGS:") {
                let raw = trimmed.dropFirst("TAGS:".count).trimmingCharacters(in: .whitespaces)
                tags = raw.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
                    .prefix(5)
                    .map { String($0) }
            }
        }

        guard fileName != nil || summary != nil || !tags.isEmpty else { return nil }
        return ScreenshotMetadata(smartFileName: fileName, summary: summary, tags: tags)
    }
}
