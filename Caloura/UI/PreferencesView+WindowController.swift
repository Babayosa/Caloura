import SwiftUI

@MainActor
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()
    private let presenter = SingleWindowPresenter<PreferencesView>()

    func show(tab: PreferencesTab? = nil) {
        if presenter.isVisible {
            presenter.bringToFront(activateApp: true)
            if let tab {
                setTab(tab)
            }
            return
        }

        let config = SingleWindowPresenter<PreferencesView>.WindowConfig(
            title: "Caloura Preferences",
            size: PreferencesLayout.minContentSize,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            minSize: PreferencesLayout.minContentSize,
            autosaveName: "PreferencesWindow"
        )
        presenter.show(config: config, activateApp: true) {
            PreferencesView(selectedTab: tab)
        }

        // Enforce minimum size when restored from autosave
        if let window = presenter.window {
            let currentContentSize = window.contentLayoutRect.size
            if currentContentSize.width < PreferencesLayout.minContentSize.width
                || currentContentSize.height < PreferencesLayout.minContentSize.height {
                window.setContentSize(PreferencesLayout.minContentSize)
            }
        }
    }

    private func setTab(_ tab: PreferencesTab) {
        guard let window = presenter.window else { return }
        let preferencesView = PreferencesView(selectedTab: tab)
        let hostingView = NSHostingView(rootView: preferencesView)
        let contentSize = window.contentView?.frame.size
            ?? PreferencesLayout.minContentSize
        hostingView.frame = CGRect(origin: .zero, size: contentSize)
        window.contentView = hostingView
    }
}
