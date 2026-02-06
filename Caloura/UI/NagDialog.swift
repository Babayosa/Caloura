import SwiftUI

struct NagDialogView: View {
    var onDismiss: () -> Void
    var onEnterKey: () -> Void
    var onBuy: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Your free trial has ended")
                .font(.title2)
                .fontWeight(.bold)

            Text("Caloura is free to keep using, but please consider purchasing a license to support development.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(spacing: 10) {
                Button(action: onBuy) {
                    Text("Buy License")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onEnterKey) {
                    Text("Enter License Key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Not Now", action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 220)
        }
        .padding(32)
        .frame(width: 400, height: 320)
    }
}

// MARK: - Nag Window Controller

@MainActor
final class NagWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func showIfNeeded() {
        let settings = AppSettings.shared
        let license = LicenseManager.shared
        guard license.shouldShowNag(settings: settings) else { return }
        show()
    }

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let view = NagDialogView(
            onDismiss: { [weak self] in
                self?.window?.close()
                self?.window = nil
            },
            onEnterKey: { [weak self] in
                self?.window?.close()
                self?.window = nil
                PreferencesWindowController.shared.show(tab: .license)
            },
            onBuy: {
                NSWorkspace.shared.open(LicenseManager.gumroadPurchaseURL)
            }
        )

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(x: 0, y: 0, width: 400, height: 320)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.title = "Caloura"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        self.window = window

        // Store observer token to avoid memory leak
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if let token = self.closeObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.closeObserver = nil
                }
                self.window = nil
            }
        }
    }
}
