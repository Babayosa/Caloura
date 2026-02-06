import SwiftUI

// MARK: - OnboardingView Step Content

extension OnboardingView {

    // MARK: - Permission Step

    var permissionStep: some View {
        VStack(spacing: 20) {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .scaleEffect(iconAppeared ? 1.0 : 0.5)
                    .opacity(iconAppeared ? 1.0 : 0.0)
            }

            VStack(spacing: 8) {
                Text("Welcome to Caloura")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("One quick step before you start capturing.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            permissionCard
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Permission Card

    var permissionCard: some View {
        VStack(spacing: 12) {
            permissionStatusRow

            permissionActionButtons

            if isAwaitingAutoCheckAfterGrant {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Auto-checking permission...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    @ViewBuilder
    var permissionStatusRow: some View {
        switch permissionPresentation.detail {
        case .working:
            Label(
                permissionPresentation.statusHeadline,
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            Text(permissionPresentation.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .grantedNotWorking:
            Label(
                permissionPresentation.statusHeadline,
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            Text(permissionPresentation.statusMessage)
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
            Button("Quit Caloura") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderedProminent)
        case .notGranted:
            Label(
                permissionPresentation.statusHeadline,
                systemImage: "lock.shield"
            )
            .foregroundStyle(.orange)
            .font(.callout)
            Text(permissionPresentation.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .signatureMismatch:
            Label(
                permissionPresentation.statusHeadline,
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            .font(.callout)
            Text(permissionPresentation.statusMessage)
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
            if permissionPresentation.shouldShowMismatchBanner {
                mismatchBanner
            }
        }
    }

    var mismatchBanner: some View {
        Text("If you run both Xcode and public builds, "
             + "macOS may authorize one build but deny the other.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 4)
            .onAppear {
                permissionCoordinator.markCurrentMismatchBannerShown()
            }
    }

    @ViewBuilder
    var permissionActionButtons: some View {
        HStack(spacing: 10) {
            if permissionPresentation.showsGrantButton {
                Button("Grant Permission") {
                    guard !isCheckingPermission,
                          !isAwaitingAutoCheckAfterGrant else { return }
                    _ = permissionCoordinator.requestPermissionFromSystem()
                    isAwaitingAutoCheckAfterGrant = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        runUserInitiatedValidation()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCheckingPermission || isAwaitingAutoCheckAfterGrant)
            }

            if permissionPresentation.showsCheckAgainButton {
                let checking = isCheckingPermission || isAwaitingAutoCheckAfterGrant
                Button(checking ? "Checking..." : "Check Again") {
                    runUserInitiatedValidation()
                }
                .buttonStyle(.bordered)
                .disabled(checking)
            }
        }
    }

    // MARK: - First Capture Step

    var firstCaptureStep: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.green.opacity(0.2), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 40
                        )
                    )
                    .frame(width: 80, height: 80)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: flow.currentStep)
            }

            Text("You\u{2019}re all set!")
                .font(.title)
                .fontWeight(.bold)

            Text("Caloura is ready to capture. Here are your shortcuts:")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            shortcutsCard

            Button {
                finishOnboarding(startCapture: true)
            } label: {
                Text("Take Your First Screenshot")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Shortcuts Card

    var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            shortcutRow(
                keys: "\u{2318}\u{21E7}4",
                action: "Capture Area",
                description: "Select any region"
            )
            shortcutRow(
                keys: "\u{2318}\u{21E7}5",
                action: "Capture Window",
                description: "Click any window"
            )
            shortcutRow(
                keys: "\u{2318}\u{21E7}3",
                action: "Capture Full Screen",
                description: "Entire display"
            )
        }
        .padding(16)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
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
                                .fill(Color.gray.opacity(0.15))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(action)
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
