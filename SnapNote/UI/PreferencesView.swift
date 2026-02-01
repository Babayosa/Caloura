import SwiftUI
import KeyboardShortcuts

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ShortcutsPreferencesView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            PresetsPreferencesView()
                .tabItem {
                    Label("Presets", systemImage: "tray.2")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}

// MARK: - General Preferences

struct GeneralPreferencesView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Save location:", text: $settings.saveDirectory)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        chooseDirectory()
                    }
                }
            }

            Section {
                Toggle("Auto-copy to clipboard", isOn: $settings.autoCopyToClipboard)
                Toggle("Auto-save to disk", isOn: $settings.autoSaveToDisk)
                Toggle("Smart crop (trim whitespace)", isOn: $settings.smartCropEnabled)
                Toggle("Play capture sound", isOn: $settings.playCaptureSound)
                Toggle("Auto-detect context", isOn: $settings.autoContextDetection)
            }

            Section {
                Picker("Image format:", selection: $settings.imageFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                    Text("TIFF").tag("tiff")
                }
                .pickerStyle(.segmented)
            }
        }
        .padding()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url.path
        }
    }
}

// MARK: - Shortcuts Preferences

extension KeyboardShortcuts.Name {
    static let captureArea = Self("captureArea", default: .init(.four, modifiers: [.control, .shift]))
    static let captureWindow = Self("captureWindow", default: .init(.five, modifiers: [.control, .shift]))
    static let captureFullscreen = Self("captureFullscreen", default: .init(.three, modifiers: [.control, .shift]))
    static let captureRepeat = Self("captureRepeat", default: .init(.r, modifiers: [.control, .shift]))
    static let copyAsMarkdown = Self("copyAsMarkdown")
    static let copyWithCitation = Self("copyWithCitation")
    static let copyOCRText = Self("copyOCRText")
}

struct ShortcutsPreferencesView: View {
    var body: some View {
        Form {
            Section("Capture") {
                HStack {
                    Text("Capture Area:")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .captureArea)
                }

                HStack {
                    Text("Capture Window:")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .captureWindow)
                }

                HStack {
                    Text("Capture Full Screen:")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .captureFullscreen)
                }

                HStack {
                    Text("Repeat Last Area:")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .captureRepeat)
                }
            }

            Section("Distribution") {
                HStack {
                    Text("Copy as Markdown:")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .copyAsMarkdown)
                }

                HStack {
                    Text("Copy with Citation:")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .copyWithCitation)
                }

                HStack {
                    Text("Copy Text (OCR):")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .copyOCRText)
                }
            }
        }
        .padding()
    }
}

// MARK: - Presets Preferences

struct PresetsPreferencesView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Active Preset") {
                Picker("Preset:", selection: $settings.activePreset) {
                    ForEach(PresetManager.builtInPresetNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }

            Section("Preset Details") {
                if let preset = PresetManager.shared.preset(named: settings.activePreset) {
                    LabeledContent("Smart Crop", value: preset.smartCropEnabled ? "On" : "Off")
                    LabeledContent("Copy Mode", value: preset.copyMode.rawValue)
                    LabeledContent("Subfolder", value: preset.subfolder ?? "None")
                } else {
                    Text("Select a preset to see details.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("SnapNote")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .foregroundStyle(.secondary)

            Text("The fastest screenshot tool for students and educators.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()

            Text("\u{00A9} 2026 SnapNote")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preferences Window Controller

@MainActor
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: PreferencesView())
        hostingView.frame = CGRect(x: 0, y: 0, width: 480, height: 360)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "SnapNote Preferences"
        window.setFrameAutosaveName("PreferencesWindow")
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
}
