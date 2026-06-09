import SwiftUI
import KeyboardShortcuts

@MainActor
@Observable
final class GlobalShortcutsWatcher {
    private(set) var version = 0

    init() {
        let name = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
        NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.version &+= 1 }
        }
    }
}

@MainActor
private func swiftUIShortcut(
    for name: KeyboardShortcuts.Name
) -> KeyboardShortcut? {
    guard let shortcut = KeyboardShortcuts.getShortcut(for: name),
          let keyString = shortcut.nsMenuItemKeyEquivalent,
          let firstChar = keyString.first else {
        return nil
    }
    var modifiers: EventModifiers = []
    if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
    if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
    if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
    if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
    return KeyboardShortcut(KeyEquivalent(firstChar), modifiers: modifiers)
}

struct MenuBarView: View {
    let appState: AppState
    var settings: AppSettings
    @State private var updateManager = UpdateManager.shared
    @State private var shortcutsWatcher = GlobalShortcutsWatcher()

    private static let recentActivityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        // Update banner
        switch updateManager.state {
        case .updateAvailable(let version):
            Button {
                updateManager.checkForUpdates()
            } label: {
                let suffix = version.map { " — v\($0)" } ?? ""
                Label(
                    "Update Available\(suffix)",
                    systemImage: "arrow.down.circle.fill"
                )
            }
            Divider()
        case .upToDate:
            Button {
                updateManager.recordUpdateDismissed()
            } label: {
                Label("Caloura is up to date", systemImage: "checkmark.circle.fill")
            }
            Divider()
        case .failed(let reason):
            Button {
                updateManager.checkForUpdates()
            } label: {
                Label("Update failed: \(reason)", systemImage: "exclamationmark.triangle.fill")
            }
            Divider()
        case .idle, .checking:
            EmptyView()
        }

        // Capture actions
        Button {
            AppCommandRouter.shared.dispatch(.captureArea)
        } label: {
            Label("Capture Area", systemImage: "rectangle.dashed")
        }
        .keyboardShortcut(swiftUIShortcut(for: .captureArea))
        .disabled(appState.isCapturing)

        Button {
            AppCommandRouter.shared.dispatch(.captureWindow)
        } label: {
            Label("Capture Window", systemImage: "macwindow")
        }
        .keyboardShortcut(swiftUIShortcut(for: .captureWindow))
        .disabled(appState.isCapturing)

        Button {
            AppCommandRouter.shared.dispatch(.captureFullscreen)
        } label: {
            Label("Capture Full Screen", systemImage: "rectangle.inset.filled")
        }
        .keyboardShortcut(swiftUIShortcut(for: .captureFullscreen))
        .disabled(appState.isCapturing)

        Button {
            AppCommandRouter.shared.dispatch(.copyLastOCRText)
        } label: {
            Label("Copy Text (OCR)", systemImage: "text.viewfinder")
        }
        .disabled(appState.lastScreenshot == nil)

        Divider()

        // More submenu — secondary capture & post-capture actions
        Menu {
            Button {
                AppCommandRouter.shared.dispatch(.captureRepeat)
            } label: {
                Label("Repeat Last Area", systemImage: "arrow.counterclockwise.circle")
            }
            .disabled(appState.lastCaptureRect == nil || appState.isCapturing)

            Menu {
                Button {
                    AppCommandRouter.shared.dispatch(
                        .captureDelayed(mode: .area, seconds: 3)
                    )
                } label: {
                    Label("Delayed Area (3s)", systemImage: "rectangle.dashed")
                }
                .disabled(appState.isCapturing)

                Button {
                    AppCommandRouter.shared.dispatch(
                        .captureDelayed(mode: .fullscreen, seconds: 3)
                    )
                } label: {
                    Label("Delayed Full Screen (3s)", systemImage: "rectangle.inset.filled")
                }
                .disabled(appState.isCapturing)

                if appState.isCountingDown {
                    Divider()
                    Button {
                        AppCommandRouter.shared.dispatch(.cancelDelayedCapture)
                    } label: {
                        Label("Cancel Countdown", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Label("Delayed Capture", systemImage: "timer")
            }

            Divider()

            Button {
                AppCommandRouter.shared.dispatch(.copyLastAsMarkdown)
            } label: {
                Label("Copy as Markdown", systemImage: "doc.text")
            }
            .disabled(appState.lastScreenshot == nil)

            Button {
                AppCommandRouter.shared.dispatch(.copyLastWithCitation)
            } label: {
                Label("Copy with Citation", systemImage: "quote.closing")
            }
            .disabled(appState.lastScreenshot == nil)

            Button {
                AppCommandRouter.shared.dispatch(.annotateLastCapture)
            } label: {
                Label("Annotate Last", systemImage: "pencil.tip")
            }
            .disabled(appState.lastScreenshot == nil)

            Button {
                AppCommandRouter.shared.dispatch(.pinScreenshot)
            } label: {
                Label("Pin Screenshot", systemImage: "pin")
            }
            .disabled(appState.lastScreenshot == nil)

            Button {
                AppCommandRouter.shared.dispatch(.beautifyLastCapture)
            } label: {
                Label("Beautify Last", systemImage: "sparkles")
            }
            .disabled(appState.lastScreenshot == nil)

            Button {
                AppCommandRouter.shared.dispatch(.redactLastCapture)
            } label: {
                Label("Redact PII", systemImage: "eye.slash")
            }
            .disabled(appState.lastScreenshot == nil)

            Divider()

            Menu("Preset: \(settings.activePreset)") {
                ForEach(PresetManager.builtInPresetNames, id: \.self) { name in
                    Button(name) {
                        settings.activePreset = name
                    }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }

        Divider()

        Button {
            AppCommandRouter.shared.dispatch(.showHistory)
        } label: {
            Label("History", systemImage: "clock")
        }

        if !appState.recentStatusMessages.isEmpty {
            Menu {
                ForEach(appState.recentStatusMessages) { entry in
                    Text(Self.recentActivityFormatter.string(from: entry.timestamp)
                        + " · " + entry.message)
                }
            } label: {
                Label("Recent activity", systemImage: "list.bullet.rectangle")
            }
        }

        Divider()

        Button {
            AppCommandRouter.shared.dispatch(.showSettings)
        } label: {
            Label("Preferences...", systemImage: "gear")
        }
        .keyboardShortcut(",")

        Button {
            AppCommandRouter.shared.dispatch(.showPermissionRepair)
        } label: {
            Label("Screen Recording...", systemImage: "lock.shield")
        }

        Button {
            updateManager.checkForUpdates()
        } label: {
            Label("Check for Updates...", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!updateManager.canCheckForUpdates)

        Button("Quit Caloura") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
