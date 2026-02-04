import SwiftUI
import os.log

private let onboardingLogger = Logger(subsystem: "com.caloura.app", category: "Onboarding")

// MARK: - Permission Detail

enum PermissionDetail: Equatable {
    case working
    case grantedNotWorking
    case notGranted
}

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @State private var currentStep = 0
    @State private var previousStep = 0  // Track direction for animation
    @State private var hasPermission = false
    @State private var permissionDetail: PermissionDetail = .notGranted
    @State private var pollCount = 0  // Track polls to show "Continue Anyway" after a few tries
    var onComplete: () -> Void

    /// Transition that moves in correct direction based on navigation
    private var stepTransition: AnyTransition {
        let isForward = currentStep > previousStep
        return .asymmetric(
            insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator - minimal line style
            HStack(spacing: 0) {
                ForEach(0..<4) { index in
                    Rectangle()
                        .fill(index <= currentStep ? Color.accentColor : Color.gray.opacity(0.2))
                        .frame(height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 1.5))
            .padding(.horizontal, 40)
            .padding(.top, 24)

            Spacer()

            // Step content with directional animation
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
            .id(currentStep)  // Force view identity change for transition
            .transition(stepTransition)

            Spacer()

            // Navigation buttons - cleaner styling
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        navigate(to: currentStep - 1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if currentStep < 3 {
                    Button("Continue") {
                        navigate(to: currentStep + 1)
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
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 480, height: 380)
        .onAppear {
            recheckPermission()
        }
        .task(id: currentStep) {
            // Auto-poll every 2 seconds while on the permission step, until granted
            guard currentStep == 1 else { return }
            while !Task.isCancelled && !hasPermission {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                await recheckPermissionAsync(userInitiated: false)
            }
        }
    }

    private func navigate(to step: Int) {
        previousStep = currentStep
        withAnimation(.easeInOut(duration: 0.25)) {
            currentStep = step
        }
    }

    private func recheckPermission(userInitiated: Bool = false) {
        Task {
            await recheckPermissionAsync(userInitiated: userInitiated)
        }
    }

    private func recheckPermissionAsync(userInitiated: Bool = false) async {
        pollCount += 1
        let previousDetail = permissionDetail

        // First check CGPreflight — this is non-intrusive and won't trigger prompts
        let cgGranted = ScreenCaptureManager.shared.checkPermission()
        if userInitiated {
            onboardingLogger.info("User-initiated permission check. CGPreflight=\(cgGranted, privacy: .public)")
        }

        if cgGranted {
            // Permission granted at OS level. Check if SCK actually works.
            // Only do this check ONCE when we first detect permission granted,
            // not on every poll (SCK check can trigger system prompts on some versions).
            if userInitiated || permissionDetail == .notGranted {
                // User explicitly asked to re-check, or first time seeing permission granted.
                let sckOK = await ScreenCaptureManager.shared.checkSCKAccess()
                if sckOK {
                    hasPermission = true
                    permissionDetail = .working
                } else {
                    hasPermission = true
                    permissionDetail = .grantedNotWorking
                }
                if userInitiated || previousDetail != permissionDetail {
                    onboardingLogger.info("SCK check result: \(sckOK, privacy: .public) detail=\(String(describing: permissionDetail), privacy: .public)")
                }
            } else {
                // Already checked SCK before, keep current state but ensure hasPermission is true
                hasPermission = true
            }
        } else {
            hasPermission = false
            permissionDetail = .notGranted
            if userInitiated {
                onboardingLogger.info("CGPreflight false on user-initiated check. Permission not granted.")
            }
        }

        if previousDetail != permissionDetail {
            onboardingLogger.info("Permission detail changed: \(String(describing: previousDetail), privacy: .public) -> \(String(describing: permissionDetail), privacy: .public)")
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
                Label("Permission granted!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Text("Please quit and reopen Caloura to activate screen capture.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)

                Button("Quit Caloura") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderedProminent)

            case .notGranted:
                Button("Grant Permission") {
                    _ = ScreenCaptureManager.shared.requestPermission()
                    // Check after a short delay to let the system process
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        recheckPermission(userInitiated: true)
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
                    recheckPermission(userInitiated: true)
                }

                // Show escape hatch after 3 poll cycles (user has been waiting ~6+ seconds)
                if pollCount >= 3 {
                    Divider()
                        .padding(.vertical, 8)

                    Text("Already granted permission?")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button("Continue Anyway") {
                        hasPermission = true
                        permissionDetail = .working
                    }
                    .buttonStyle(.bordered)
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
    private var closeObserver: NSObjectProtocol?

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
        hostingView.frame = CGRect(x: 0, y: 0, width: 480, height: 380)

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
