import Foundation

@MainActor
private final class WeakUpdateManagerBox {
    weak var manager: UpdateManager?
}

extension UpdateManager {
    static let shared: UpdateManager = {
        let settings = AppSettings.shared
        let box = WeakUpdateManagerBox()
        let delegateHandler = UpdateDelegateHandler(
            onUpdateFound: { [weak box] version in
                box?.manager?.recordUpdateFound(version: version)
            },
            onNoUpdateFound: { [weak box] state in
                box?.manager?.recordNoUpdate(state)
            },
            onUpdateDismissed: { [weak box] in
                box?.manager?.recordUpdateDismissed()
            },
            onUpdateFailed: { [weak box] state in
                box?.manager?.recordUpdateFailure(state)
            },
            onUpdateCycleFinished: { [weak box] state in
                box?.manager?.finishUpdateCycle(state: state)
            }
        )
        let manager = UpdateManager(
            settings: settings,
            controller: SparkleUpdateController(delegate: delegateHandler),
            delegateHandler: delegateHandler
        )
        box.manager = manager
        return manager
    }()
}
