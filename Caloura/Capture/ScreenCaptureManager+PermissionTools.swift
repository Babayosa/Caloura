import Foundation

struct PermissionRepairProcessError: LocalizedError {
    let tool: String
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "\(tool) exited with status \(status)."
        }
        return "\(tool) exited with status \(status): \(trimmed)"
    }
}

extension ScreenCaptureManager {
    static func runRepairTool(
        _ executableURL: URL,
        arguments: [String]
    ) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let stderrPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardError = stderrPipe
            try process.run()
            process.waitUntilExit()

            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw PermissionRepairProcessError(
                    tool: executableURL.lastPathComponent,
                    status: process.terminationStatus,
                    stderr: stderr
                )
            }
        }.value
    }
}
