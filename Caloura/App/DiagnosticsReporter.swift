import Foundation
import MetricKit
import os.log

/// Local-only MetricKit crash + hang capture. Writes JSON payloads to
/// `~/Library/Application Support/Caloura/diagnostics/` and rotates files
/// older than 30 days. Never uploads — users attach to support email
/// if needed, matching the app's local-only privacy positioning.
@MainActor
final class DiagnosticsReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsReporter()

    private static let retentionDays: Double = 30
    private let logger = Logger(subsystem: "com.caloura.app", category: "Diagnostics")
    private let fileManager = FileManager.default
    private lazy var diagnosticsDirectory: URL? = {
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = appSupport.appendingPathComponent("Caloura/diagnostics", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var isSubscribed = false

    override private init() { super.init() }

    func start() {
        // Idempotent — avoid duplicate subscriptions if called more than
        // once (e.g. re-entrancy in tests).
        guard !isSubscribed else { return }
        MXMetricManager.shared.add(self)
        isSubscribed = true
        Task.detached(priority: .background) { [weak self] in
            await self?.rotateOldPayloads()
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // MXDiagnosticPayload isn't Sendable; extract Data (which is) before
        // hopping to main actor for file I/O.
        let blobs = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor [weak self] in
            self?.persist(blobs)
        }
    }

    private func persist(_ blobs: [Data]) {
        guard let dir = diagnosticsDirectory else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        for data in blobs {
            let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let filename = "diagnostic-\(stamp)-\(UUID().uuidString.prefix(8)).json"
            let url = dir.appendingPathComponent(filename)
            do {
                try data.write(to: url, options: .atomic)
                logger.info("Wrote MetricKit diagnostic payload to \(filename, privacy: .public)")
            } catch {
                let description = error.localizedDescription
                logger.error("Failed to write diagnostic payload: \(description)")
            }
        }
    }

    private func rotateOldPayloads() async {
        guard let dir = diagnosticsDirectory else { return }
        let cutoff = Date().addingTimeInterval(-Self.retentionDays * 86_400)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in contents {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}
