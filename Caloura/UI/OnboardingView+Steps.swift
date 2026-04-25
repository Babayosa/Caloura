import SwiftUI
import KeyboardShortcuts

@MainActor
private func onboardingShortcutDisplay(
    for name: KeyboardShortcuts.Name,
    fallback: String
) -> String {
    guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else {
        return fallback
    }
    let description = shortcut.description.trimmingCharacters(in: .whitespaces)
    return description.isEmpty ? fallback : description
}

extension OnboardingView {

    var installStep: some View {
        VStack(spacing: 22) {
            heroIcon(symbol: "arrow.down.app.fill", tint: .orange)

            VStack(spacing: 10) {
                Text("Install Caloura in Applications")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Finish the install first so Screen Recording, updates, and the first-launch experience all stay attached to the same app copy.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)
            }

            infoCard {
                VStack(alignment: .leading, spacing: 12) {
                    installRow(
                        title: "Current location",
                        value: AppMover.sourceBundlePath()
                    )
                    installRow(
                        title: "Recommended location",
                        value: "/Applications/Caloura.app"
                    )

                    if installState == .moving {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Moving Caloura and relaunching the installed copy…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let failure = installState.failureMessage {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.leading)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)

                Button("Move to Applications") {
                    moveToApplications()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 28)
    }

    var readyForFirstCaptureStep: some View {
        VStack(spacing: 20) {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .scaleEffect(iconAppeared ? 1.0 : 0.7)
                    .opacity(iconAppeared ? 1.0 : 0.0)
            }

            VStack(spacing: 10) {
                Text("Take your first screenshot")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Start with one capture. Caloura will ask for Screen Recording only when it is actually needed, then get you straight into capture mode.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)
            }

            shortcutsCard

            HStack(spacing: 12) {
                Button("Not Now") {
                    dismissWindow()
                }
                .buttonStyle(.bordered)

                Button("Take Your First Screenshot") {
                    startFirstCapture()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 28)
    }

    var permissionStep: some View {
        VStack(spacing: 20) {
            heroIcon(symbol: permissionSymbol, tint: permissionTint)

            VStack(spacing: 10) {
                Text(permissionTitle)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(permissionBody)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)
            }

            infoCard {
                VStack(spacing: 14) {
                    permissionStatusRow

                    if permissionPresentation.shouldShowStaleRecordBanner {
                        staleRecordBanner
                    }
                }
            }

            permissionActions
        }
        .padding(.horizontal, 28)
    }

    var completionStep: some View {
        VStack(spacing: 18) {
            heroIcon(symbol: "checkmark.circle.fill", tint: .green)

            Text(settings.hasCompletedOnboarding ? "Permission repaired" : "Starting your first capture…")
                .font(.title2)
                .fontWeight(.bold)

            Text(settings.hasCompletedOnboarding
                 ? "Caloura is ready again."
                 : "The overlay will appear in a moment.")
                .font(.body)
                .foregroundStyle(.secondary)

            ProgressView()
                .controlSize(.small)
        }
        .padding(.horizontal, 28)
    }

    private var permissionSymbol: String {
        switch flow.currentState {
        case .waitingForSettingsReturn:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .repairStalePermissionRecord:
            return "exclamationmark.triangle.fill"
        default:
            return "lock.shield.fill"
        }
    }

    private var permissionTint: Color {
        switch flow.currentState {
        case .repairStalePermissionRecord:
            return .orange
        case .waitingForSettingsReturn:
            return .blue
        default:
            return .accentColor
        }
    }

    private var permissionTitle: String {
        switch flow.currentState {
        case .waitingForSettingsReturn:
            return "Finish Screen Recording in System Settings"
        case .repairStalePermissionRecord:
            switch permissionPresentation.detail {
            case .staleRecord:
                return "Fix the Screen Recording record"
            case .grantedNeedsValidation:
                return "Finish validating Screen Recording"
            default:
                return "Finish applying Screen Recording"
            }
        default:
            return "Grant Screen Recording when you’re ready"
        }
    }

    private var permissionBody: String {
        switch flow.currentState {
        case .waitingForSettingsReturn:
            if isAutoValidatingAfterSettings {
                return "Validating permission… macOS can take a few seconds to propagate this. Caloura will keep checking — or press Try Again."
            }
            return "In System Settings, click the \"+\" button, select Caloura, and enable it. Then return here — Caloura will re-check automatically."
        case .repairStalePermissionRecord:
            switch permissionPresentation.detail {
            case .staleRecord:
                return "macOS is still pointing Screen Recording at a different Caloura copy. Use the installed app and refresh the permission once."
            case .grantedNeedsValidation:
                return "Caloura has a matching Screen Recording record, but macOS still needs one successful live validation before capture can continue."
            default:
                return "macOS has the permission record, but the current app process still needs a clean relaunch."
            }
        default:
            return "Caloura only asks for Screen Recording when you start a real capture."
        }
    }

    @ViewBuilder
    private var permissionStatusRow: some View {
        switch permissionPresentation.detail {
        case .working:
            Label(permissionPresentation.statusHeadline, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(permissionPresentation.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .grantedNeedsValidation:
            Label(permissionPresentation.statusHeadline, systemImage: "scope")
                .foregroundStyle(.blue)
            Text(permissionPresentation.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .needsRelaunch:
            Label(permissionPresentation.statusHeadline, systemImage: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
            Text(permissionPresentation.statusMessage)
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        case .notGranted:
            Label(permissionPresentation.statusHeadline, systemImage: "lock.shield")
                .foregroundStyle(Color.accentColor)
            Text(permissionPresentation.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .staleRecord:
            Label(permissionPresentation.statusHeadline, systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text(permissionPresentation.statusMessage)
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        case .repairing:
            Label(permissionPresentation.statusHeadline, systemImage: "gearshape.2.fill")
                .foregroundStyle(.blue)
            ProgressView()
                .controlSize(.small)
            Text(permissionPresentation.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .configurationFailed:
            Label(permissionPresentation.statusHeadline, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(permissionPresentation.statusMessage)
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    private var staleRecordBanner: some View {
        Text("If you moved Caloura after granting access, open the installed copy from /Applications before re-checking.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var permissionActions: some View {
        switch flow.currentState {
        case .waitingForSettingsReturn:
            VStack(spacing: 10) {
                if isCheckingPermission || isAutoValidatingAfterSettings {
                    ProgressView(isAutoValidatingAfterSettings ? "Validating permission…" : "Checking Screen Recording…")
                        .controlSize(.small)
                }

                Button(isAutoValidatingAfterSettings ? "Try Again" : "Check Again") {
                    revalidateAfterSettingsReturn()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCheckingPermission)
            }
        case .repairStalePermissionRecord:
            HStack(spacing: 12) {
                if permissionPresentation.detail == .staleRecord {
                    Button("Open /Applications Copy") {
                        launchInstalledCopy()
                    }
                    .buttonStyle(.bordered)
                }

                if permissionPresentation.showsResetRelaunchButton {
                    Button("Reset & Relaunch") {
                        Task { @MainActor in
                            await permissionCoordinator.performTCCResetAndRelaunch()
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Button(permissionPresentation.showsRepairButton ? "Check Again" : "Done") {
                    if permissionPresentation.showsRepairButton || permissionPresentation.showsCheckAgainButton {
                        runUserInitiatedValidation(launchCaptureOnSuccess: false)
                    } else {
                        dismissWindow()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCheckingPermission)
            }
        default:
            HStack(spacing: 12) {
                Button("Not Now") {
                    dismissWindow()
                }
                .buttonStyle(.bordered)

                Button("Grant Screen Recording") {
                    requestScreenRecording()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func heroIcon(symbol: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.22), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 44
                    )
                )
                .frame(width: 88, height: 88)

            Image(systemName: symbol)
                .font(.system(size: 48))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: flow.currentState)
        }
    }

    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) {
            content()
        }
        .padding(18)
        .frame(maxWidth: 430)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private func installRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var shortcutsCard: some View {
        infoCard {
            VStack(alignment: .leading, spacing: 12) {
                shortcutRow(
                    keys: onboardingShortcutDisplay(for: .captureArea, fallback: "\u{2303}\u{2325}C"),
                    action: "Capture Area",
                    description: "Select any region"
                )
                shortcutRow(
                    keys: onboardingShortcutDisplay(for: .captureWindow, fallback: "\u{2303}\u{2325}W"),
                    action: "Capture Window",
                    description: "Click any window"
                )
                shortcutRow(
                    keys: onboardingShortcutDisplay(for: .captureFullscreen, fallback: "\u{2303}\u{2325}F"),
                    action: "Capture Full Screen",
                    description: "Entire display"
                )
            }
        }
    }

    func shortcutRow(
        keys: String,
        action: String,
        description: String
    ) -> some View {
        HStack {
            HStack(spacing: 3) {
                ForEach(Array(keys), id: \.self) { key in
                    Text(String(key))
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .frame(minWidth: 28, minHeight: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(action)
                    .font(.body.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}
