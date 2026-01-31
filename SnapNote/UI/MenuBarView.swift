import SwiftUI
import KeyboardShortcuts

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            // Capture actions
            Section {
                Button {
                    NotificationCenter.default.post(name: .captureArea, object: nil)
                } label: {
                    Label("Capture Area", systemImage: "rectangle.dashed")
                }
                .keyboardShortcut("4", modifiers: [.control, .shift])

                Button {
                    NotificationCenter.default.post(name: .captureWindow, object: nil)
                } label: {
                    Label("Capture Window", systemImage: "macwindow")
                }
                .keyboardShortcut("5", modifiers: [.control, .shift])

                Button {
                    NotificationCenter.default.post(name: .captureFullscreen, object: nil)
                } label: {
                    Label("Capture Full Screen", systemImage: "rectangle.inset.filled")
                }
                .keyboardShortcut("3", modifiers: [.control, .shift])

                Button {
                    NotificationCenter.default.post(name: .captureRepeat, object: nil)
                } label: {
                    Label("Repeat Last Area", systemImage: "arrow.counterclockwise.circle")
                }
                .disabled(appState.lastCaptureRect == nil)

                Menu {
                    Button {
                        NotificationCenter.default.post(name: .captureDelayedArea, object: nil)
                    } label: {
                        Label("Delayed Area (3s)", systemImage: "rectangle.dashed")
                    }

                    Button {
                        NotificationCenter.default.post(name: .captureDelayedFullscreen, object: nil)
                    } label: {
                        Label("Delayed Full Screen (3s)", systemImage: "rectangle.inset.filled")
                    }
                } label: {
                    Label("Delayed Capture", systemImage: "timer")
                }
            }

            Divider()

            // Last capture actions
            if appState.lastScreenshot != nil {
                Section {
                    Button {
                        NotificationCenter.default.post(name: .copyLastAsMarkdown, object: nil)
                    } label: {
                        Label("Copy as Markdown", systemImage: "doc.text")
                    }

                    Button {
                        NotificationCenter.default.post(name: .copyLastWithCitation, object: nil)
                    } label: {
                        Label("Copy with Citation", systemImage: "quote.closing")
                    }

                    Button {
                        NotificationCenter.default.post(name: .copyLastOCRText, object: nil)
                    } label: {
                        Label("Copy Text (OCR)", systemImage: "text.viewfinder")
                    }

                    Button {
                        NotificationCenter.default.post(name: .annotateLastCapture, object: nil)
                    } label: {
                        Label("Annotate Last", systemImage: "pencil.tip")
                    }

                    Button {
                        NotificationCenter.default.post(name: .pinScreenshot, object: nil)
                    } label: {
                        Label("Pin Screenshot", systemImage: "pin")
                    }
                }

                Divider()
            }

            // Preset selection
            Section {
                Menu("Preset: \(settings.activePreset)") {
                    ForEach(PresetManager.builtInPresetNames, id: \.self) { name in
                        Button(name) {
                            settings.activePreset = name
                        }
                    }
                }
            }

            Divider()

            // History & Settings
            Section {
                Button {
                    NotificationCenter.default.post(name: .showHistory, object: nil)
                } label: {
                    Label("History", systemImage: "clock")
                }

                SettingsButton()
            }

            Divider()

            Button("Quit SnapNote") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let captureArea = Notification.Name("captureArea")
    static let captureWindow = Notification.Name("captureWindow")
    static let captureFullscreen = Notification.Name("captureFullscreen")
    static let captureRepeat = Notification.Name("captureRepeat")
    static let captureDelayedArea = Notification.Name("captureDelayedArea")
    static let captureDelayedFullscreen = Notification.Name("captureDelayedFullscreen")
    static let copyLastAsMarkdown = Notification.Name("copyLastAsMarkdown")
    static let copyLastWithCitation = Notification.Name("copyLastWithCitation")
    static let copyLastOCRText = Notification.Name("copyLastOCRText")
    static let annotateLastCapture = Notification.Name("annotateLastCapture")
    static let pinScreenshot = Notification.Name("pinScreenshot")
    static let showHistory = Notification.Name("showHistory")
    static let captureCompleted = Notification.Name("captureCompleted")
}

// MARK: - Settings Button Workaround

struct SettingsButton: View {
    var body: some View {
        Button {
            openSettings()
        } label: {
            Label("Preferences...", systemImage: "gear")
        }
        .keyboardShortcut(",")
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
