import SwiftUI
import KeyboardShortcuts

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updateManager = UpdateManager.shared

    var body: some View {
        // Update banner
        if updateManager.updateAvailable {
            Button {
                updateManager.checkForUpdates()
            } label: {
                let suffix = updateManager.updateVersion
                    .map { " — v\($0)" } ?? ""
                Label(
                    "Update Available\(suffix)",
                    systemImage: "arrow.down.circle.fill"
                )
            }
            Divider()
        }

        // Capture actions
        Button {
            AppCommandRouter.shared.dispatch(.captureArea)
        } label: {
            Label("Capture Area", systemImage: "rectangle.dashed")
        }
        .keyboardShortcut("4", modifiers: [.command, .shift])
        .disabled(appState.isCapturing)

        Button {
            AppCommandRouter.shared.dispatch(.captureWindow)
        } label: {
            Label("Capture Window", systemImage: "macwindow")
        }
        .keyboardShortcut("5", modifiers: [.command, .shift])
        .disabled(appState.isCapturing)

        Button {
            AppCommandRouter.shared.dispatch(.captureFullscreen)
        } label: {
            Label("Capture Full Screen", systemImage: "rectangle.inset.filled")
        }
        .keyboardShortcut("3", modifiers: [.command, .shift])
        .disabled(appState.isCapturing)

        Button {
            AppCommandRouter.shared.dispatch(.captureScroll)
        } label: {
            Label("Scroll Capture", systemImage: "rectangle.bottomhalf.inset.filled")
        }
        .keyboardShortcut("6", modifiers: [.command, .shift])
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
