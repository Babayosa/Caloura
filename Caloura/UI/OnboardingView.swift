import SwiftUI

// MARK: - Permission Detail

enum PermissionDetail {
    case working
    case grantedNotWorking
    case notGranted
}

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @State private var currentStep = 0
    @State private var hasPermission = false
    @State private var permissionDetail: PermissionDetail = .notGranted
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<4) { index in
                    Circle()
                        .fill(index <= currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)

            Spacer()

            // Step content
            Group {
                switch currentStep {
                case 0:
                    welcomeStep
                case 1:
                    permissionsStep
                case 2:
                    shortcutsStep
                case 3:
                    readyStep
                default:
                    EmptyView()
                }
            }
            .transition(.slide)

            Spacer()

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                }

                Spacer()

                if currentStep < 3 {
                    Button("Next") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentStep == 1 && !hasPermission)
                } else {
                    Button("Get Started") {
                        settings.hasCompletedOnboarding = true
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(width: 480, height: 400)
        .onAppear {
            recheckPermission()
        }
        .task(id: currentStep) {
            // Auto-poll every 2 seconds while on the permission step
            guard currentStep == 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                await recheckPermissionAsync()
            }
        }
    }

    private func recheckPermission() {
        Task {
            await recheckPermissionAsync()
        }
    }

    private func recheckPermissionAsync() async {
        // SCK is the authoritative check — if it works, permission is fully functional
        let sckOK = await ScreenCaptureManager.shared.checkSCKAccess()
        if sckOK {
            hasPermission = true
            permissionDetail = .working
            return
        }

        // SCK failed — check CGPreflight (authoritative OS-level check).
        // CGWindowList fallback was removed: it gives false positives on Sequoia.
        if ScreenCaptureManager.shared.checkPermission() {
            hasPermission = true
            permissionDetail = .grantedNotWorking
        } else {
            hasPermission = false
            permissionDetail = .notGranted
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to Caloura")
                .font(.title)
                .fontWeight(.bold)

            Text("The fastest screenshot tool for students and educators.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Zero-decision capture: Hotkey \u{2192} auto-crop \u{2192} auto-copy \u{2192} auto-organize.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Screen Recording Permission")
                .font(.title2)
                .fontWeight(.bold)

            Text("Caloura needs screen recording access to capture screenshots. macOS will prompt you to grant this permission.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            switch permissionDetail {
            case .working:
                Label("Permission granted and working!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case .grantedNotWorking:
                Label("Permission granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("App restart may be needed for captures to work.")
                    .font(.callout)
                    .foregroundStyle(.orange)

            case .notGranted:
                Button("Grant Permission") {
                    _ = ScreenCaptureManager.shared.requestPermission()
                    // Check after a short delay to let the system process
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        recheckPermission()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)

                Button("Check Again") {
                    recheckPermission()
                }
            }
        }
    }

    private var shortcutsStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "keyboard")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Default Shortcuts")
                .font(.title2)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 12) {
                shortcutRow(keys: "\u{2303}\u{21E7}4", action: "Capture Area")
                shortcutRow(keys: "\u{2303}\u{21E7}5", action: "Capture Window")
                shortcutRow(keys: "\u{2303}\u{21E7}3", action: "Capture Full Screen")
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            Text("You can customize these in Preferences > Shortcuts.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var readyStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.title)
                .fontWeight(.bold)

            Text("Try pressing \u{2303}\u{21E7}4 to capture your first screenshot.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func shortcutRow(keys: String, action: String) -> some View {
        HStack {
            HStack(spacing: 3) {
                ForEach(Array(keys), id: \.self) { key in
                    Text(String(key))
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .frame(minWidth: 28, minHeight: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.15))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }
            }
            Text(action)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Onboarding Window Controller

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func showIfNeeded(settings: AppSettings) {
        guard !settings.hasCompletedOnboarding else { return }
        show(settings: settings)
    }

    func show(settings: AppSettings) {
        // If already showing, just bring to front
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingView(settings: settings) { [weak self] in
            self?.window?.close()
            self?.window = nil
        }

        let hostingView = NSHostingView(rootView: onboardingView)
        hostingView.frame = CGRect(x: 0, y: 0, width: 480, height: 400)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.title = "Welcome to Caloura"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window

        // Nil out window reference when closed via the close button
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window = nil
            }
        }
    }
}
