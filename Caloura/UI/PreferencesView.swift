import ServiceManagement
import SwiftUI
import KeyboardShortcuts

// MARK: - Tab Enum

enum PreferencesTab: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case presets
    case license
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .presets: "Presets"
        case .license: "License"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .shortcuts: "keyboard"
        case .presets: "slider.horizontal.3"
        case .license: "dollarsign.circle"
        case .about: "info.circle"
        }
    }
}

// MARK: - Preferences View

struct PreferencesView: View {
    @State var selectedTab: PreferencesTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // Icon tab bar
            HStack(spacing: 0) {
                ForEach(PreferencesTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 18))
                            Text(tab.label)
                                .font(.system(size: 10))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    .background(
                        selectedTab == tab
                            ? Color.accentColor.opacity(0.1)
                            : Color.clear
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case .general:
                    GeneralPreferencesView()
                case .shortcuts:
                    ShortcutsPreferencesView()
                case .presets:
                    PresetsPreferencesView()
                case .license:
                    LicensePreferencesView()
                case .about:
                    AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            settings.launchAtLogin = !newValue
                        }
                    }
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

// MARK: - License Preferences

struct LicensePreferencesView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var license = LicenseManager.shared
    @State private var keyInput = ""
    @State private var isActivating = false

    var body: some View {
        VStack(spacing: 20) {
            // Status badge
            Group {
                switch license.activationState {
                case .licensed:
                    Label("Licensed", systemImage: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                case .trial(let days):
                    Label("Free Trial \u{2014} \(days) day\(days == 1 ? "" : "s") remaining", systemImage: "clock")
                        .font(.title2)
                        .foregroundStyle(.blue)
                case .expired:
                    Label("Trial Expired", systemImage: "clock.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.orange)
                case .checking:
                    ProgressView()
                        .controlSize(.small)
                case .activationFailed(let msg):
                    Label(msg, systemImage: "xmark.circle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            if !settings.isLicenseActivated {
                Divider()

                VStack(spacing: 12) {
                    TextField("License key", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)

                    HStack(spacing: 12) {
                        Button("Activate") {
                            isActivating = true
                            Task {
                                await license.activate(licenseKey: keyInput)
                                isActivating = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty || isActivating)

                        Button("Buy License") {
                            NSWorkspace.shared.open(LicenseManager.gumroadPurchaseURL)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            keyInput = settings.licenseKey
        }
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Caloura")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .foregroundStyle(.secondary)

            Text("The fastest screenshot tool for students and educators.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()

            Text("\u{00A9} 2026 Caloura")
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

    func show(tab: PreferencesTab? = nil) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let tab {
                setTab(tab)
            }
            return
        }

        let preferencesView = PreferencesView(selectedTab: tab ?? .general)
        let hostingView = NSHostingView(rootView: preferencesView)
        hostingView.frame = CGRect(x: 0, y: 0, width: 480, height: 360)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.title = "Caloura Preferences"
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

    private func setTab(_ tab: PreferencesTab) {
        // Re-create the hosting view with the desired tab selected
        guard let window else { return }
        let preferencesView = PreferencesView(selectedTab: tab)
        let hostingView = NSHostingView(rootView: preferencesView)
        hostingView.frame = window.contentView?.frame ?? CGRect(x: 0, y: 0, width: 480, height: 360)
        window.contentView = hostingView
    }
}
