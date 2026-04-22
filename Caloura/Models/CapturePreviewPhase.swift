import Foundation

enum CapturePreviewPhase: String, Equatable {
    case rawPreviewReady
    case enrichmentPending
    case enrichmentComplete
    case enrichmentFailed
    /// Enrichment otherwise completed (OCR / metadata / embedding ran),
    /// but the PII scan threw and was skipped. Distinguished from
    /// `.enrichmentComplete` so telemetry and UI can surface that the
    /// capture was stored without scanning instead of hiding the failure.
    case piiScanFailed
}
