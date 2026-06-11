import AppKit
import SwiftUI

@MainActor
final class BeautifyPreviewController {
    static let shared = BeautifyPreviewController()
    private let presenter = SingleWindowPresenter<BeautifyPreviewView>()

    var debugWindow: NSWindow? {
        presenter.window
    }

    func show(screenshot: ProcessedScreenshot) {
        presenter.show(
            config: .init(
                title: "Beautify Screenshot",
                size: CGSize(width: 640, height: 520),
                styleMask: [.titled, .closable, .resizable],
                minSize: CGSize(width: 480, height: 400),
                autosaveName: "CalouraBeautifyPreview",
                sharingType: .none
            ),
            activateApp: true
        ) {
            BeautifyPreviewView(screenshot: screenshot)
        }
    }

    func close() {
        presenter.close()
    }
}

struct BeautifyPreviewView: View {
    let screenshot: ProcessedScreenshot

    @State private var selectedTheme = BeautifyTheme.builtInThemes
        .first { $0.name == AppSettings.shared.beautifyThemeName }
        ?? BeautifyTheme.builtInThemes[0]
    @State private var previewImage: CGImage?
    @State private var isProcessing = false

    var body: some View {
        VStack(spacing: 12) {
            // Preview area
            Group {
                if let preview = previewImage {
                    Image(decorative: preview, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if isProcessing {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(decorative: screenshot.cgImage, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Theme picker
            HStack(spacing: 8) {
                ForEach(BeautifyTheme.builtInThemes) { theme in
                    Button {
                        selectedTheme = theme
                    } label: {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(themePreviewGradient(theme))
                                .frame(width: 40, height: 30)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(selectedTheme.id == theme.id ? Color.accentColor : Color.clear, lineWidth: 2)
                                )
                            Text(theme.name)
                                .font(.system(size: 10))
                                .foregroundStyle(selectedTheme.id == theme.id ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Actions
            HStack {
                Button("Cancel") {
                    BeautifyPreviewController.shared.close()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Copy") {
                    guard let image = previewImage else { return }
                    copyToClipboard(image)
                    BeautifyPreviewController.shared.close()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    guard let image = previewImage else { return }
                    saveImage(image)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 400)
        .task(id: selectedTheme.id) {
            await generatePreview()
        }
    }

    private func generatePreview() async {
        isProcessing = true
        let result = await Beautifier.beautify(cgImage: screenshot.cgImage, theme: selectedTheme)
        previewImage = result
        isProcessing = false
    }

    private func themePreviewGradient(_ theme: BeautifyTheme) -> LinearGradient {
        let colors = theme.gradientColors.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func copyToClipboard(_ cgImage: CGImage) {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        do {
            try ClipboardManager.copyNSImage(nsImage)
            AppState.shared.statusMessage = "Beautified image copied"
        } catch {
            AppState.shared.statusMessage = error.localizedDescription
        }
    }

    private func saveImage(_ cgImage: CGImage) {
        Task {
            do {
                _ = try await ScreenshotArtifactCoordinator.shared.saveDerivedCapture(
                    cgImage,
                    basedOn: screenshot,
                    suggestedSuffix: "beautified"
                )
                AppState.shared.statusMessage = "Beautified image saved"
                BeautifyPreviewController.shared.close()
            } catch is CancellationError {
                AppState.shared.statusMessage = "Beautify save cancelled"
            } catch {
                AppState.shared.statusMessage = "Overwrite failed: \(error.localizedDescription)"
            }
        }
    }
}
