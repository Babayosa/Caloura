import Foundation
@testable import Caloura

final class PermissionDependencyBox: @unchecked Sendable {
    var runRepairToolCalls: [(URL, [String])] = []
    var openedURLs: [URL] = []
    var terminateCount = 0
    var onTerminate: (() -> Void)?
}

func makePermissionDependencies(
    box: PermissionDependencyBox = PermissionDependencyBox(),
    preflight: @escaping @Sendable () -> Bool = { true },
    request: @escaping @Sendable () -> Bool = { false },
    sckProbe: @escaping @Sendable () async -> ScreenCaptureAccessProbeResult = {
        .authorized
    },
    alertAction: ScreenCapturePermissionAlertAction = .cancel,
    relaunchResult: Result<Void, Error> = .success(()),
    runRepairTool: @escaping @Sendable (URL, [String]) async throws -> Void = { _, _ in },
    statusMessageSink: (@MainActor @Sendable (String) -> Void)? = nil
) -> ScreenCapturePermissionDependencies {
    ScreenCapturePermissionDependencies(
        cgPreflight: preflight,
        cgRequest: request,
        sckAccessProbe: sckProbe,
        runRepairTool: { url, arguments in
            try await runRepairTool(url, arguments)
            box.runRepairToolCalls.append((url, arguments))
        },
        presentAlert: { _ in
            alertAction
        },
        openURL: { url in
            box.openedURLs.append(url)
        },
        relaunchApplication: { _ in
            try relaunchResult.get()
        },
        terminateApplication: {
            box.terminateCount += 1
            box.onTerminate?()
        },
        statusMessageSink: statusMessageSink
    )
}
