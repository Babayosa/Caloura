import ServiceManagement
import SwiftUI
import KeyboardShortcuts

// MARK: - Tab Enum

enum PreferencesLayout {
    static let minContentSize = CGSize(width: 560, height: 520)
}

enum PreferencesTab: String, CaseIterable, Identifiable {
    case welcome
    case general
    case shortcuts
    case presets
    case license
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .welcome: "Welcome"
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .presets: "Presets"
        case .license: "License"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .welcome: "hand.wave"
        case .general: "gear"
        case .shortcuts: "keyboard"
        case .presets: "slider.horizontal.3"
        case .license: "dollarsign.circle"
        case .about: "info.circle"
        }
    }

    /// Tabs to show based on whether user has seen welcome
    static func visibleTabs(hasSeenWelcome: Bool) -> [PreferencesTab] {
        if hasSeenWelcome {
            return [.general, .shortcuts, .presets, .license, .about]
        } else {
            return [.welcome, .general, .shortcuts, .presets, .license, .about]
        }
    }
}

// MARK: - Preferences View

struct PreferencesView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedTab: PreferencesTab

    init(selectedTab: PreferencesTab? = nil) {
        if let selectedTab {
            _selectedTab = State(initialValue: selectedTab)
        } else {
            // Start on welcome tab if user hasn't seen it yet
            _selectedTab = State(initialValue: AppSettings.shared.hasSeenWelcome ? .general : .welcome)
        }
    }

    private var visibleTabs: [PreferencesTab] {
        PreferencesTab.visibleTabs(hasSeenWelcome: settings.hasSeenWelcome)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Icon tab bar
            HStack(spacing: 2) {
                ForEach(visibleTabs) { tab in
                    Button {
                        let wasOnWelcome = selectedTab == .welcome
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                        // Mark welcome as seen when user navigates away from it
                        if wasOnWelcome && tab != .welcome && !settings.hasSeenWelcome {
                            settings.hasSeenWelcome = true
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 20, weight: selectedTab == tab ? .medium : .regular))
                            Text(tab.label)
                                .font(.system(size: 10, weight: selectedTab == tab ? .medium : .regular))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.12))
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case .welcome:
                    WelcomePreferencesView {
                        settings.hasSeenWelcome = true
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = .general
                        }
                    }
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
        .frame(minWidth: PreferencesLayout.minContentSize.width,
               minHeight: PreferencesLayout.minContentSize.height)
    }
}

// MARK: - General Preferences

struct GeneralPreferencesView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Startup") {
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
                Toggle("Check for Updates Automatically", isOn: $settings.checkForUpdatesAutomatically)
            }

            Section("Capture") {
                Toggle("Smart crop (trim whitespace)", isOn: $settings.smartCropEnabled)
                Toggle("Play capture sound", isOn: $settings.playCaptureSound)
                Toggle("Auto-detect context", isOn: $settings.autoContextDetection)
                Toggle("Low-profile capture", isOn: $settings.lowProfileCaptureEnabled)
                Text("Reduces system-level side effects that may trigger browser "
                    + "event handlers (exam platforms, auto-save). "
                    + "Disables freeze snapshot. Window capture unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Copy to clipboard", isOn: $settings.autoCopyToClipboard)
                Toggle("Save to disk", isOn: $settings.autoSaveToDisk)
                if !settings.autoSaveToDisk {
                    Text("Screenshots will only be copied to clipboard and won't use disk space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("After Capture")
            }

            if settings.autoSaveToDisk {
                Section("Output") {
                    LabeledContent("Save location") {
                        HStack {
                            Text(settings.saveDirectory)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Browse...") {
                                chooseDirectory()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Picker("Image format", selection: $settings.imageFormat) {
                        Text("PNG").tag("png")
                        Text("JPEG").tag("jpeg")
                        Text("TIFF").tag("tiff")
                    }
                    .pickerStyle(.segmented)
                }
            }

            Section("Appearance") {
                Picker("Beautify Theme", selection: $settings.beautifyThemeName) {
                    ForEach(BeautifyTheme.builtInThemes) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                }
            }

            Section("AI Features") {
                Toggle("Smart names, summaries & tags", isOn: $settings.smartMetadataEnabled)
                Toggle("Semantic search", isOn: $settings.semanticSearchEnabled)
                Text("Uses on-device AI to generate descriptive filenames, "
                    + "one-line summaries, topic tags, and meaning-based search. "
                    + "No data leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Auto-detect sensitive info (PII)", isOn: $settings.autoDetectPII)
                Text("Scans screenshots for emails, phone numbers, credit cards, "
                    + "API keys, and other sensitive data. Detected items appear "
                    + "in the Quick Access overlay for review before redaction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
    static let captureArea = Self("captureArea", default: .init(.four, modifiers: [.control, .option]))
    static let captureWindow = Self("captureWindow", default: .init(.five, modifiers: [.control, .option]))
    static let captureFullscreen = Self("captureFullscreen", default: .init(.three, modifiers: [.control, .option]))
    static let captureRepeat = Self("captureRepeat", default: .init(.r, modifiers: [.command, .shift]))
    static let copyAsMarkdown = Self("copyAsMarkdown")
    static let copyWithCitation = Self("copyWithCitation")
    static let copyOCRText = Self("copyOCRText")
}

struct ShortcutsPreferencesView: View {
    var body: some View {
        Form {
            Section("Capture") {
                KeyboardShortcuts.Recorder("Capture Area", name: .captureArea)
                KeyboardShortcuts.Recorder("Capture Window", name: .captureWindow)
                KeyboardShortcuts.Recorder("Capture Full Screen", name: .captureFullscreen)
                KeyboardShortcuts.Recorder("Repeat Last Area", name: .captureRepeat)
            }

            Section("Clipboard") {
                KeyboardShortcuts.Recorder("Copy as Markdown", name: .copyAsMarkdown)
                KeyboardShortcuts.Recorder("Copy with Citation", name: .copyWithCitation)
                KeyboardShortcuts.Recorder("Copy Text (OCR)", name: .copyOCRText)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Presets Preferences

struct PresetsPreferencesView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Active Preset", selection: $settings.activePreset) {
                    ForEach(PresetManager.builtInPresetNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }

            if let preset = PresetManager.shared.preset(named: settings.activePreset) {
                Section("Preset Configuration") {
                    LabeledContent("Smart Crop") {
                        Text(preset.smartCropEnabled ? "Enabled" : "Disabled")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Copy Mode") {
                        Text(preset.copyMode.rawValue.capitalized)
                            .foregroundStyle(.secondary)
                    }
                    if let subfolder = preset.subfolder {
                        LabeledContent("Subfolder") {
                            Text(subfolder)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Text("Presets automatically adjust capture settings based on your workflow. "
                    + "Choose a preset that matches what you're capturing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
