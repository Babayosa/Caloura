import AppKit
import CryptoKit
import Foundation
import os.log

final class CaptureEnrichmentService {
    typealias RecognizeTextFn = @Sendable (CGImage) async throws -> String
    typealias DetectPIIFn = @Sendable (CGImage) async throws -> [PIIDetection]
    typealias EmbedTextFn = @Sendable (String) -> [Double]?
    typealias GenerateMetadataFn = @Sendable (String, String?, String?) async -> ScreenshotMetadata?

    private struct Dependencies: Sendable {
        let recognizeText: RecognizeTextFn
        let detectPII: DetectPIIFn
        let embedText: EmbedTextFn
        let generateMetadata: GenerateMetadataFn
        let logger: Logger
        let updateOCRText: @Sendable (UUID, String) async -> Void
        let setPIIResult: @Sendable (PIIDetectionResult) async -> Void
        let setPreviewPhase: @Sendable (CapturePreviewPhase, UUID) async -> Void
        let piiDetectionEnabled: @Sendable () async -> Bool
        let semanticSearchEnabled: @Sendable () async -> Bool
        let smartMetadataEnabled: @Sendable () async -> Bool
        let storeEmbedding: @Sendable (UUID, [Double], String) async -> Void
        let metadataContext: @Sendable (UUID) async -> (String?, String?)
        let applyMetadata: @Sendable (ScreenshotMetadata, UUID) async -> Void
    }

    private let appState: AppState
    private let settings: AppSettings
    private let recognizeText: RecognizeTextFn
    private let detectPII: DetectPIIFn
    private let embedText: EmbedTextFn
    private let generateMetadata: GenerateMetadataFn
    private let enrichmentCoordinator: CaptureEnrichmentCoordinator
    private let logger = Logger(subsystem: "com.caloura.app", category: "CaptureEnrichment")

    init(
        appState: AppState,
        settings: AppSettings,
        recognizeText: @escaping RecognizeTextFn,
        detectPII: @escaping DetectPIIFn = { try await PIIDetector.detect(in: $0) },
        embedText: @escaping EmbedTextFn = { text in
            EmbeddingEngine.embed(text)
        },
        generateMetadata: @escaping GenerateMetadataFn = { text, sourceApp, windowTitle in
            await SmartMetadataGenerator.shared.generate(
                ocrText: text,
                sourceApp: sourceApp,
                windowTitle: windowTitle
            )
        },
        enrichmentCoordinator: CaptureEnrichmentCoordinator
    ) {
        self.appState = appState
        self.settings = settings
        self.recognizeText = recognizeText
        self.detectPII = detectPII
        self.embedText = embedText
        self.generateMetadata = generateMetadata
        self.enrichmentCoordinator = enrichmentCoordinator
    }

    @MainActor
    func enqueueEnrichment(for screenshot: ProcessedScreenshot) {
        appState.syncProcessedScreenshot(screenshot)
        let screenshotID = screenshot.id
        let cgImage = screenshot.cgImage
        let coordinator = enrichmentCoordinator
        let dependencies = makeDependencies()

        Task {
            await coordinator.enqueue(screenshotID: screenshotID) {
                await Self.runEnrichment(
                    screenshotID: screenshotID,
                    cgImage: cgImage,
                    dependencies: dependencies
                )
            }
        }
    }

    @MainActor
    private func makeDependencies() -> Dependencies {
        let appState = appState
        let settings = settings
        let recognizeText = recognizeText
        let detectPII = detectPII
        let embedText = embedText
        let generateMetadata = generateMetadata
        let logger = logger

        return Dependencies(
            recognizeText: recognizeText,
            detectPII: detectPII,
            embedText: embedText,
            generateMetadata: generateMetadata,
            logger: logger,
            updateOCRText: { screenshotID, text in
                await MainActor.run {
                    appState.updateScreenshot(id: screenshotID) { item in
                        item.ocrText = text
                    }
                }
            },
            setPIIResult: { piiResult in
                await MainActor.run {
                    appState.setPIIResult(piiResult)
                }
            },
            setPreviewPhase: { phase, screenshotID in
                await MainActor.run {
                    appState.setCapturePreviewPhase(phase, for: screenshotID)
                }
            },
            piiDetectionEnabled: {
                await MainActor.run { settings.autoDetectPII }
            },
            semanticSearchEnabled: {
                await MainActor.run { settings.semanticSearchEnabled }
            },
            smartMetadataEnabled: {
                await MainActor.run { settings.smartMetadataEnabled }
            },
            storeEmbedding: { screenshotID, vector, textHash in
                let store = await MainActor.run { appState.embeddingStore }
                store.add(
                    screenshotID: screenshotID,
                    vector: vector,
                    textHash: textHash
                )
                store.save()

                await MainActor.run {
                    appState.markEmbeddingVersion(
                        EmbeddingEngine.modelVersion,
                        for: screenshotID
                    )
                }
            },
            metadataContext: { screenshotID in
                await MainActor.run {
                    let item = appState.recentScreenshots.first { $0.id == screenshotID }
                    return (item?.sourceAppName, item?.sourceWindowTitle)
                }
            },
            applyMetadata: { metadata, screenshotID in
                await MainActor.run {
                    appState.applyMetadata(metadata, to: screenshotID)
                }
            }
        )
    }

    private static func runEnrichment(
        screenshotID: UUID,
        cgImage: CGImage,
        dependencies: Dependencies
    ) async {
        do {
            async let piiResult = detectPIIIfEnabled(
                cgImage: cgImage,
                screenshotID: screenshotID,
                dependencies: dependencies
            )

            guard !Task.isCancelled else { return }
            let text = try await dependencies.recognizeText(cgImage)
            guard !Task.isCancelled else { return }

            if !text.isEmpty {
                await dependencies.updateOCRText(screenshotID, text)

                if let piiResult = await piiResult {
                    await dependencies.setPIIResult(piiResult)
                }

                await generateEmbeddingIfEnabled(
                    text: text,
                    screenshotID: screenshotID,
                    dependencies: dependencies
                )
                await generateSmartMetadataIfEnabled(
                    text: text,
                    screenshotID: screenshotID,
                    dependencies: dependencies
                )
            } else {
                _ = await piiResult
            }

            await dependencies.setPreviewPhase(.enrichmentComplete, screenshotID)
        } catch {
            guard !Task.isCancelled else { return }
            let description = error.localizedDescription
            dependencies.logger.error("OCR failed: \(description, privacy: .public)")
            await dependencies.setPreviewPhase(.enrichmentFailed, screenshotID)
        }
    }

    private static func detectPIIIfEnabled(
        cgImage: CGImage,
        screenshotID: UUID,
        dependencies: Dependencies
    ) async -> PIIDetectionResult? {
        let enabled = await dependencies.piiDetectionEnabled()
        guard enabled else { return nil }

        do {
            let detections = try await dependencies.detectPII(cgImage)
            guard !detections.isEmpty else { return nil }
            return PIIDetectionResult(
                detections: detections,
                screenshotID: screenshotID
            )
        } catch {
            return nil
        }
    }

    private static func generateEmbeddingIfEnabled(
        text: String,
        screenshotID: UUID,
        dependencies: Dependencies
    ) async {
        let enabled = await dependencies.semanticSearchEnabled()
        guard enabled, !text.isEmpty else { return }
        guard let vector = dependencies.embedText(text) else { return }

        let textHash = stableHash(text)
        await dependencies.storeEmbedding(screenshotID, vector, textHash)
    }

    private static func generateSmartMetadataIfEnabled(
        text: String,
        screenshotID: UUID,
        dependencies: Dependencies
    ) async {
        let enabled = await dependencies.smartMetadataEnabled()
        guard enabled, !text.isEmpty else { return }

        let (sourceApp, windowTitle) = await dependencies.metadataContext(screenshotID)

        guard let metadata = await dependencies.generateMetadata(text, sourceApp, windowTitle) else {
            return
        }

        await dependencies.applyMetadata(metadata, screenshotID)
    }

    private static func stableHash(_ text: String) -> String {
        let data = Data(text.utf8)
        return SHA256.hash(data: data)
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
