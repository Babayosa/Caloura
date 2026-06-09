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

            Text(
                """
                Caloura keeps all its features — your captures, history, and shortcuts still work. \
                A license removes this reminder and directly supports continued development.
                """
            )
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
    private let presenter = SingleWindowPresenter<NagDialogView>()

    func showIfNeeded() {
        let settings = AppSettings.shared
        let license = LicenseManager.shared
        guard license.shouldShowNag(settings: settings) else { return }
        show(activateApp: false)
    }

    func show(activateApp: Bool = true) {
        let config = SingleWindowPresenter<NagDialogView>.WindowConfig(
            title: "Caloura",
            size: CGSize(width: 400, height: 320)
        )
        presenter.show(config: config, activateApp: activateApp) {
            NagDialogView(
                onDismiss: { [weak self] in
                    self?.presenter.close()
                },
                onEnterKey: { [weak self] in
                    self?.presenter.close()
                    PreferencesWindowController.shared.show(tab: .license)
                },
                onBuy: {
                    NSWorkspace.shared.open(LicenseManager.gumroadPurchaseURL)
                }
            )
        }
    }
}
