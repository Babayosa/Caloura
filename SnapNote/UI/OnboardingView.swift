import SwiftUI

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @State private var currentStep = 0
    @State private var hasPermission = false
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
            hasPermission = ScreenCaptureManager.shared.checkPermission()
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to SnapNote")
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

            Text("SnapNote needs screen recording access to capture screenshots. macOS will prompt you to grant this permission.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if hasPermission {
                Label("Permission granted!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant Permission") {
                    _ = ScreenCaptureManager.shared.requestPermission()
                    // Check after a short delay to let the system process
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        hasPermission = ScreenCaptureManager.shared.checkPermission()
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
                    hasPermission = ScreenCaptureManager.shared.checkPermission()
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
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(4)
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
        window.contentView = hostingView
        window.title = "Welcome to SnapNote"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
