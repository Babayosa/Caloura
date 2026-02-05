import SwiftUI

@MainActor
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(tab: PreferencesTab? = nil) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let tab {
                setTab(tab)
            }
            return
        }

        let preferencesView = PreferencesView(selectedTab: tab)
        let hostingView = NSHostingView(rootView: preferencesView)
        hostingView.frame = CGRect(
            origin: .zero, size: PreferencesLayout.minContentSize
        )

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.title = "Caloura Preferences"
        window.contentMinSize = PreferencesLayout.minContentSize
        window.setFrameAutosaveName("PreferencesWindow")
        let currentContentSize = window.contentLayoutRect.size
        if currentContentSize.width < PreferencesLayout.minContentSize.width ||
            currentContentSize.height < PreferencesLayout.minContentSize.height {
            window.setContentSize(PreferencesLayout.minContentSize)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window = nil
                if let token = self?.closeObserver {
                    NotificationCenter.default.removeObserver(token)
                    self?.closeObserver = nil
                }
            }
        }

        self.window = window
    }

    private func setTab(_ tab: PreferencesTab) {
        guard let window else { return }
        let preferencesView = PreferencesView(selectedTab: tab)
        let hostingView = NSHostingView(rootView: preferencesView)
        let contentSize = window.contentView?.frame.size
            ?? PreferencesLayout.minContentSize
        hostingView.frame = CGRect(origin: .zero, size: contentSize)
        window.contentView = hostingView
    }
}
