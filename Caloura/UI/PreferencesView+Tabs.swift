import SwiftUI

// MARK: - License Preferences

struct LicensePreferencesView: View {
    @Bindable private var settings = AppSettings.shared
    private var license = LicenseManager.shared
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
                        .disabled(
                            keyInput.trimmingCharacters(in: .whitespaces).isEmpty
                            || isActivating
                        )

                        Button("Buy License") {
                            NSWorkspace.shared.open(
                                LicenseManager.gumroadPurchaseURL
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section {
                    Text(
                        "Purchase a license to remove the trial reminder "
                        + "and support development. "
                        + "Your license key will be emailed after purchase."
                    )
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
            Label(
                "Free Trial \u{2014} \(days) day\(days == 1 ? "" : "s") remaining",
                systemImage: "clock"
            )
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
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "1"
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
                    if let url = URL(string: "https://caloura.app") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)

                Button("Support") {
                    if let url = URL(string: "https://caloura.app/#faq") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)

                Button("Twitter") {
                    if let url = URL(string: "https://twitter.com/calouraapp") {
                        NSWorkspace.shared.open(url)
                    }
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
