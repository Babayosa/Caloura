import ServiceManagement
import SwiftUI
import KeyboardShortcuts

// MARK: - Tab Enum

private enum PreferencesLayout {
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

// MARK: - Welcome Preferences

struct WelcomePreferencesView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "hand.wave.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Hi there!")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Welcome to Caloura")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            Text("You're all set up and ready to capture.\nExplore the tabs above to customize your experience.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("**Shortcuts** — Customize your capture hotkeys")
                        .font(.callout)
                }

                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("**Presets** — Different modes for different workflows")
                        .font(.callout)
                }

                HStack(spacing: 8) {
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("**General** — Output format, save location, and more")
                        .font(.callout)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            Button("Let's Go") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
                Text("Presets automatically adjust capture settings based on your workflow. Choose a preset that matches what you're capturing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - License Preferences

struct LicensePreferencesView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var license = LicenseManager.shared
    @State private var keyInput = ""
    @State private var isActivating = false

    var body: some View {
        Form {
            // Status section
            Section {
                HStack {
                    Spacer()
                    statusBadge
                    Spacer()
                }
                .padding(.vertical, 8)
            }

            // Activation section (only shown when not licensed)
            if !settings.isLicenseActivated {
                Section("Activate License") {
                    TextField("License key", text: $keyInput)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button {
                            isActivating = true
                            Task {
                                await license.activate(licenseKey: keyInput)
                                isActivating = false
                            }
                        } label: {
                            if isActivating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Activate")
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

                Section {
                    Text("Purchase a license to remove the trial reminder and support development. Your license key will be emailed after purchase.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Licensed state - show license info
                Section("License Details") {
                    LabeledContent("Status") {
                        Text("Active")
                            .foregroundStyle(.green)
                    }
                    if !settings.licenseKey.isEmpty {
                        LabeledContent("License Key") {
                            Text(maskedLicenseKey)
                                .foregroundStyle(.secondary)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                Section {
                    Text("Thank you for supporting Caloura!")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            keyInput = settings.licenseKey
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch license.activationState {
        case .licensed:
            Label("Licensed", systemImage: "checkmark.seal.fill")
                .font(.title2.bold())
                .foregroundStyle(.green)
        case .trial(let days):
            Label("Free Trial \u{2014} \(days) day\(days == 1 ? "" : "s") remaining", systemImage: "clock")
                .font(.title2.bold())
                .foregroundStyle(.blue)
        case .expired:
            Label("Trial Expired", systemImage: "clock.badge.exclamationmark")
                .font(.title2.bold())
                .foregroundStyle(.orange)
        case .checking:
            ProgressView()
                .controlSize(.regular)
        case .activationFailed(let msg):
            Label(msg, systemImage: "xmark.circle")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private var maskedLicenseKey: String {
        let key = settings.licenseKey
        guard key.count > 8 else { return key }
        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(4))
        return "\(prefix)••••••••\(suffix)"
    }
}

// MARK: - About View

struct AboutView: View {
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // App icon and info
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 80, height: 80)
            } else {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 4) {
                Text("Caloura")
                    .font(.title.bold())

                Text("Version \(appVersion) (\(buildNumber))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("The fastest screenshot tool for students and educators.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            Spacer()

            // Links
            HStack(spacing: 20) {
                Button("Website") {
                    NSWorkspace.shared.open(URL(string: "https://caloura.app")!)
                }
                .buttonStyle(.link)

                Button("Support") {
                    NSWorkspace.shared.open(URL(string: "https://caloura.app/#faq")!)
                }
                .buttonStyle(.link)

                Button("Twitter") {
                    NSWorkspace.shared.open(URL(string: "https://twitter.com/calouraapp")!)
                }
                .buttonStyle(.link)
            }
            .font(.callout)

            Spacer()

            Text("\u{00A9} 2026 Caloura. All rights reserved.")
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

        let preferencesView = PreferencesView(selectedTab: tab)
        let hostingView = NSHostingView(rootView: preferencesView)
        hostingView.frame = CGRect(origin: .zero, size: PreferencesLayout.minContentSize)

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
        // Re-create the hosting view with the desired tab selected
        guard let window else { return }
        let preferencesView = PreferencesView(selectedTab: tab)
        let hostingView = NSHostingView(rootView: preferencesView)
        let contentSize = window.contentView?.frame.size ?? PreferencesLayout.minContentSize
        hostingView.frame = CGRect(origin: .zero, size: contentSize)
        window.contentView = hostingView
    }
}
