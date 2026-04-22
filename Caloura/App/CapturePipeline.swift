import AppKit
import Observation

@Observable @MainActor
final class CapturePipeline {
    static let shared = CapturePipeline()

    fileprivate struct ServiceDependencies {
        let settings: AppSettings
        let appState: AppState
        let detectContext: DetectContextFn
        let presetForCategory: PresetForCategoryFn
        let presetByName: PresetByNameFn
        let copyToClipboard: CopyToClipboardFn
        let saveCaptureAction: SaveCaptureActionFn
        let playSoundAction: PlaySoundFn
        let recognizeText: RecognizeTextFn
    }

    fileprivate struct Services {
        let requestResolver: CaptureRequestResolver
        let enrichmentService: CaptureEnrichmentService
        let distributionService: CaptureDistributionService
    }

    // MARK: - Closure Type Aliases

    typealias DetectContextFn = () -> DetectedContext
    typealias ProcessImageFn = (CGImage, CaptureContext, Bool) async -> ProcessedScreenshot
    typealias PersistArtifactFn = (ProcessedScreenshot, CapturePreset) async throws -> Void
    typealias CopyToClipboardFn = (ProcessedScreenshot, CopyMode) async throws -> Void
    typealias SaveCaptureActionFn = @MainActor (ProcessedScreenshot) async throws -> URL
    typealias RecognizeTextFn = @Sendable (CGImage) async throws -> String
    typealias HandlePermissionFailureFn = @MainActor (CaptureMode) async -> Void
    typealias ShowQuickAccessFn = (ProcessedScreenshot) -> Void
    typealias PlaySoundFn = () -> Void
    typealias PostNotificationFn = (Notification.Name) -> Void
    typealias PresetForCategoryFn = (AppCategory) -> CapturePreset?
    typealias PresetByNameFn = (String) -> CapturePreset?
    typealias SelectWindowCaptureFn = @MainActor (
        @escaping @MainActor () -> Void
    ) async -> WindowCaptureSessionCoordinator.SelectionResult
    typealias MakeAreaCaptureSessionFn = @MainActor (
        CapturePerformanceRecorder.Session,
        @escaping AreaCaptureSessionCoordinator.SelectionHandler,
        @escaping AreaCaptureSessionCoordinator.CancelHandler,
        AreaCaptureSessionCoordinator.EventHandler?
    ) -> any AreaCaptureSessionHandling
    typealias MakeFullscreenCaptureSessionFn = @MainActor (
        CapturePerformanceRecorder.Session,
        @escaping FullscreenCaptureSessionCoordinator.SelectionHandler,
        @escaping FullscreenCaptureSessionCoordinator.CancelHandler
    ) -> any FullscreenCaptureSessionHandling
    typealias MakeWindowCaptureSessionFn = @MainActor (
        CapturePerformanceRecorder.Session,
        @escaping @MainActor () async -> Void,
        @escaping SelectWindowCaptureFn
    ) -> any WindowCaptureSessionHandling

    // MARK: - Dependencies

    let captureManager: ScreenCaptureManaging
    let capturePerformanceRecorder: CapturePerformanceRecorder
    let settings: AppSettings
    let appState: AppState
    private let processImage: ProcessImageFn
    private let persistArtifact: PersistArtifactFn
    let handlePermissionFailure: HandlePermissionFailureFn
    private let showQuickAccess: ShowQuickAccessFn
    private let postNotification: PostNotificationFn
    let selectWindowCapture: SelectWindowCaptureFn
    let makeAreaCaptureSession: MakeAreaCaptureSessionFn
    let makeFullscreenCaptureSession: MakeFullscreenCaptureSessionFn
    let makeWindowCaptureSession: MakeWindowCaptureSessionFn
    let screenCountProvider: () -> Int
    let screensProvider: () -> [NSScreen]
    let mainScreenProvider: () -> NSScreen?
    let delaySleeper: (UInt64) async -> Void
    let freezeScreensEnabled: Bool
    private let enrichmentCoordinator: CaptureEnrichmentCoordinator
    let metricsRecorder: CaptureMetricsRecorder
    let freezeService: CaptureFreezeService

    // MARK: - Mutable State

    let sessionState = CaptureSessionState()
    private let requestResolver: CaptureRequestResolver
    let distributionService: CaptureDistributionService
    private let enrichmentService: CaptureEnrichmentService
    @ObservationIgnored lazy var executionService = makeCaptureExecutionService()
    @ObservationIgnored lazy var entrypointService = makeCaptureEntrypointService()

    // MARK: - Init (Production)

    private init() {
        let performanceRecorder = CapturePerformanceRecorder.shared
        self.captureManager = ScreenCaptureManager.shared
        self.capturePerformanceRecorder = performanceRecorder
        self.settings = AppSettings.shared
        self.appState = AppState.shared
        let presetMgr = PresetManager.shared
        self.processImage = { cgImage, context, smartCrop in
            await ImageProcessor.process(
                cgImage: cgImage, context: context, smartCropEnabled: smartCrop
            )
        }
        self.persistArtifact = { processed, preset in
            _ = try await ScreenshotArtifactCoordinator.shared.saveCapture(
                processed,
                subfolder: preset.subfolder
            )
        }
        let copyToClipboard = makeCapturePipelineCopyToClipboard()
        let saveCaptureAction: SaveCaptureActionFn = { screenshot in
            try await ScreenshotArtifactCoordinator.shared.saveCapture(screenshot)
        }
        let recognizeText: RecognizeTextFn = { cgImage in
            try await OCREngine.recognizeText(in: cgImage)
        }
        self.handlePermissionFailure = { mode in
            PermissionCoordinator.shared.armPendingCaptureResume(mode: mode)
            await PermissionCoordinator.shared.handleCapturePermissionFailure()
        }
        self.showQuickAccess = { processed in
            QuickAccessOverlay.shared.show(for: processed)
        }
        let playSoundAction: PlaySoundFn = {
            NSSound(named: "Tink")?.play()
        }
        self.postNotification = { name in
            NotificationCenter.default.post(name: name, object: nil)
        }
        let detectContext: DetectContextFn = { ContextDetector.detectContext() }
        let presetForCategory: PresetForCategoryFn = { category in
            presetMgr.presetForCategory(category)
        }
        let presetByName: PresetByNameFn = { name in
            presetMgr.preset(named: name)
        }
        self.selectWindowCapture = makeCapturePipelineSelectWindowCapture(
            captureManager: self.captureManager
        )
        self.makeAreaCaptureSession = makeCapturePipelineAreaCaptureSessionFactory(
            performanceRecorder: performanceRecorder,
            cursorController: self.sessionState.cursorController
        )
        self.makeFullscreenCaptureSession = makeCapturePipelineFullscreenCaptureSessionFactory(
            performanceRecorder: performanceRecorder,
            cursorController: self.sessionState.cursorController
        )
        self.makeWindowCaptureSession = makeCapturePipelineWindowCaptureSessionFactory(
            performanceRecorder: performanceRecorder,
            captureManager: self.captureManager
        )
        self.screenCountProvider = { NSScreen.screens.count }
        self.screensProvider = { NSScreen.screens }
        self.mainScreenProvider = { NSScreen.main }
        self.delaySleeper = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
        self.freezeScreensEnabled = true
        self.enrichmentCoordinator = CaptureEnrichmentCoordinator()
        self.metricsRecorder = .shared
        self.freezeService = .shared
        let services = makeCapturePipelineServices(
            dependencies: ServiceDependencies(
                settings: self.settings,
                appState: self.appState,
                detectContext: detectContext,
                presetForCategory: presetForCategory,
                presetByName: presetByName,
                copyToClipboard: copyToClipboard,
                saveCaptureAction: saveCaptureAction,
                playSoundAction: playSoundAction,
                recognizeText: recognizeText
            ),
            enrichmentCoordinator: self.enrichmentCoordinator
        )
        self.requestResolver = services.requestResolver
        self.enrichmentService = services.enrichmentService
        self.distributionService = services.distributionService
    }

    // MARK: - Init (Testing)

    init(
        settings: AppSettings,
        appState: AppState,
        captureManager: ScreenCaptureManaging?,
        capturePerformanceRecorder: CapturePerformanceRecorder,
        detectContext: @escaping DetectContextFn,
        processImage: @escaping ProcessImageFn,
        persistArtifact: @escaping PersistArtifactFn,
        copyToClipboard: @escaping CopyToClipboardFn,
        saveCaptureAction: SaveCaptureActionFn? = nil,
        recognizeText: @escaping RecognizeTextFn,
        handlePermissionFailure: @escaping HandlePermissionFailureFn,
        showQuickAccess: @escaping ShowQuickAccessFn,
        playSoundAction: @escaping PlaySoundFn,
        postNotification: @escaping PostNotificationFn,
        presetForCategory: @escaping PresetForCategoryFn,
        presetByName: @escaping PresetByNameFn,
        selectWindowCapture: @escaping SelectWindowCaptureFn = { _ in .cancelled },
        makeAreaCaptureSession: MakeAreaCaptureSessionFn? = nil,
        makeFullscreenCaptureSession: MakeFullscreenCaptureSessionFn? = nil,
        makeWindowCaptureSession: MakeWindowCaptureSessionFn? = nil,
        screenCountProvider: @escaping () -> Int = { NSScreen.screens.count },
        screensProvider: @escaping () -> [NSScreen] = { NSScreen.screens },
        mainScreenProvider: @escaping () -> NSScreen? = { NSScreen.main },
        delaySleeper: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        freezeScreensEnabled: Bool = true,
        freezeSnapshotTimeoutSeconds: Double = 2.0,
        enrichmentCoordinator: CaptureEnrichmentCoordinator = CaptureEnrichmentCoordinator(),
        metricsRecorder: CaptureMetricsRecorder = CaptureMetricsRecorder(),
        freezeService: CaptureFreezeService? = nil
    ) {
        let resolvedCaptureManager = captureManager ?? ScreenCaptureManager.shared
        self.captureManager = resolvedCaptureManager
        self.capturePerformanceRecorder = capturePerformanceRecorder
        self.settings = settings
        self.appState = appState
        self.processImage = processImage
        self.persistArtifact = persistArtifact
        self.handlePermissionFailure = handlePermissionFailure
        self.showQuickAccess = showQuickAccess
        self.postNotification = postNotification
        self.selectWindowCapture = selectWindowCapture
        let sharedCursor = self.sessionState.cursorController
        self.makeAreaCaptureSession = makeAreaCaptureSession ?? { session, onSelection, onCancel, onFirstInteraction in
            AreaCaptureSessionCoordinator(
                session: session,
                performanceRecorder: capturePerformanceRecorder,
                cursorController: sharedCursor,
                onSelection: onSelection,
                onCancel: onCancel,
                onFirstInteraction: onFirstInteraction
            )
        }
        self.makeFullscreenCaptureSession = makeFullscreenCaptureSession ?? { session, onSelection, onCancel in
            FullscreenCaptureSessionCoordinator(
                session: session,
                performanceRecorder: capturePerformanceRecorder,
                cursorController: sharedCursor,
                onSelection: onSelection,
                onCancel: onCancel
            )
        }
        self.makeWindowCaptureSession = makeWindowCaptureSession ?? { session, prewarmContent, selectWindowCapture in
            WindowCaptureSessionCoordinator(
                session: session,
                performanceRecorder: capturePerformanceRecorder,
                hasWarmContent: resolvedCaptureManager.hasWarmWindowShareableContent,
                prewarmContent: {
                    await prewarmContent()
                },
                pickWindow: selectWindowCapture
            )
        }
        self.screenCountProvider = screenCountProvider
        self.screensProvider = screensProvider
        self.mainScreenProvider = mainScreenProvider
        self.delaySleeper = delaySleeper
        self.freezeScreensEnabled = freezeScreensEnabled
        self.enrichmentCoordinator = enrichmentCoordinator
        self.metricsRecorder = metricsRecorder
        self.freezeService = freezeService ?? CaptureFreezeService(
            captureManager: captureManager ?? ScreenCaptureManager.shared,
            metricsRecorder: metricsRecorder,
            freezeSnapshotTimeoutSeconds: freezeSnapshotTimeoutSeconds
        )
        let resolvedSaveCaptureAction = saveCaptureAction ?? { screenshot in
            let presetName = screenshot.presetName
            let preset = presetName.flatMap(presetByName) ?? CapturePreset(name: "Quick Capture")
            try await persistArtifact(screenshot, preset)
            guard let url = screenshot.filePath else {
                throw CaptureError.noContent(source: "Saved capture artifact")
            }
            return url
        }
        let services = makeCapturePipelineServices(
            dependencies: ServiceDependencies(
                settings: settings,
                appState: appState,
                detectContext: detectContext,
                presetForCategory: presetForCategory,
                presetByName: presetByName,
                copyToClipboard: copyToClipboard,
                saveCaptureAction: resolvedSaveCaptureAction,
                playSoundAction: playSoundAction,
                recognizeText: recognizeText
            ),
            enrichmentCoordinator: enrichmentCoordinator
        )
        self.requestResolver = services.requestResolver
        self.enrichmentService = services.enrichmentService
        self.distributionService = services.distributionService
    }

}

@MainActor
private func makeCapturePipelineCopyToClipboard() -> CapturePipeline.CopyToClipboardFn {
    { processed, copyMode in
        switch copyMode {
        case .image:
            try await ClipboardManager.copyImage(processed)
        case .markdown:
            try ClipboardManager.copyAsMarkdown(processed)
        case .citation:
            try ClipboardManager.copyWithCitation(processed)
        case .multiFormat:
            try await ClipboardManager.copyMultiFormat(processed)
        }
    }
}

@MainActor
private func makeCapturePipelineSelectWindowCapture(
    captureManager: any ScreenCaptureManaging
) -> CapturePipeline.SelectWindowCaptureFn {
    { onPresented in
        let result = await WindowPickerManager.shared.pickWindow(onPresented: onPresented)
        switch result {
        case .selected:
            return .selected {
                try await WindowPickerManager.shared.captureSelectedWindow(
                    using: captureManager
                )
            }
        case .cancelled:
            return .cancelled
        case .failedToStart:
            return .failedToStart
        }
    }
}

@MainActor
private func makeCapturePipelineAreaCaptureSessionFactory(
    performanceRecorder: CapturePerformanceRecorder,
    cursorController: CaptureCursorControlling
) -> CapturePipeline.MakeAreaCaptureSessionFn {
    { session, onSelection, onCancel, onFirstInteraction in
        AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: performanceRecorder,
            cursorController: cursorController,
            onSelection: onSelection,
            onCancel: onCancel,
            onFirstInteraction: onFirstInteraction
        )
    }
}

@MainActor
private func makeCapturePipelineFullscreenCaptureSessionFactory(
    performanceRecorder: CapturePerformanceRecorder,
    cursorController: CaptureCursorControlling
) -> CapturePipeline.MakeFullscreenCaptureSessionFn {
    { session, onSelection, onCancel in
        FullscreenCaptureSessionCoordinator(
            session: session,
            performanceRecorder: performanceRecorder,
            cursorController: cursorController,
            onSelection: onSelection,
            onCancel: onCancel
        )
    }
}

@MainActor
private func makeCapturePipelineWindowCaptureSessionFactory(
    performanceRecorder: CapturePerformanceRecorder,
    captureManager: ScreenCaptureManaging
) -> CapturePipeline.MakeWindowCaptureSessionFn {
    { session, prewarmContent, selectWindowCapture in
        WindowCaptureSessionCoordinator(
            session: session,
            performanceRecorder: performanceRecorder,
            hasWarmContent: captureManager.hasWarmWindowShareableContent,
            prewarmContent: {
                await prewarmContent()
            },
            pickWindow: selectWindowCapture
        )
    }
}

@MainActor
private func makeCapturePipelineServices(
    dependencies: CapturePipeline.ServiceDependencies,
    enrichmentCoordinator: CaptureEnrichmentCoordinator
) -> CapturePipeline.Services {
    let requestResolver = CaptureRequestResolver(
        settings: dependencies.settings,
        detectContext: dependencies.detectContext,
        presetForCategory: dependencies.presetForCategory,
        presetByName: dependencies.presetByName
    )
    let enrichmentService = CaptureEnrichmentService(
        appState: dependencies.appState,
        settings: dependencies.settings,
        recognizeText: dependencies.recognizeText,
        enrichmentCoordinator: enrichmentCoordinator
    )
    let distributionService = CaptureDistributionService(
        appState: dependencies.appState,
        copyToClipboard: dependencies.copyToClipboard,
        saveCapture: dependencies.saveCaptureAction,
        playSound: dependencies.playSoundAction,
        enqueueEnrichment: { screenshot in
            enrichmentService.enqueueEnrichment(for: screenshot)
        },
        dispatchCommand: { command in
            AppCommandRouter.shared.dispatch(command)
        },
        showTip: { tip in
            OnboardingTipsController.shared.showIfNeeded(tip)
        },
        dismissQuickAccess: {
            QuickAccessOverlay.shared.dismiss()
        }
    )

    return .init(
        requestResolver: requestResolver,
        enrichmentService: enrichmentService,
        distributionService: distributionService
    )
}

private extension CapturePipeline {
    func makeCaptureExecutionService() -> CaptureExecutionService {
        CaptureExecutionService(
            settings: settings,
            appState: appState,
            requestResolver: requestResolver,
            distributionService: distributionService,
            enrichmentService: enrichmentService,
            capturePerformanceRecorder: capturePerformanceRecorder,
            processImage: processImage,
            persistArtifact: persistArtifact,
            handlePermissionFailure: handlePermissionFailure,
            showQuickAccess: showQuickAccess,
            postNotification: postNotification,
            metricsRecorder: metricsRecorder
        )
    }

}
