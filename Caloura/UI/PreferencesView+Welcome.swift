import SwiftUI

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

            Text(
                "You're all set up and ready to capture.\n"
                + "Explore the tabs above to customize your experience."
            )
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
            .clipShape(RoundedRectangle(cornerRadius: 8))

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
