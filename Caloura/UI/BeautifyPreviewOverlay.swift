import AppKit
import SwiftUI

@MainActor
final class BeautifyPreviewController {
    static let shared = BeautifyPreviewController()
    private let presenter = SingleWindowPresenter<BeautifyPreviewView>()

    func show(screenshot: ProcessedScreenshot) {
        presenter.show(
            config: .init(
                title: "Beautify Screenshot",
                size: CGSize(width: 640, height: 520),
                styleMask: [.titled, .closable, .resizable],
                minSize: CGSize(width: 480, height: 400),
                autosaveName: "CalouraBeautifyPreview"
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

    @State private var selectedTheme = defaultSelectedTheme()
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
                        AppSettings.shared.beautifyThemeName = theme.name
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
                .disabled(previewImage == nil || isProcessing)

                Button("Save") {
                    guard let image = previewImage else { return }
                    saveImage(image)
                }
                .buttonStyle(.borderedProminent)
                .disabled(previewImage == nil || isProcessing)
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
        defer { isProcessing = false }
        let result = await Beautifier.beautify(cgImage: screenshot.cgImage, theme: selectedTheme)
        guard !Task.isCancelled else { return }
        previewImage = result
    }

    private static func defaultSelectedTheme() -> BeautifyTheme {
        if let saved = BeautifyTheme.builtInThemes.first(where: {
            $0.name == AppSettings.shared.beautifyThemeName
        }) {
            return saved
        }
        guard let first = BeautifyTheme.builtInThemes.first else {
            preconditionFailure("At least one built-in beautify theme is required")
        }
        return first
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
            AppState.shared.statusMessage = UserFacingErrorMessage.message(for: error)
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
                AppState.shared.statusMessage = "Save failed: \(UserFacingErrorMessage.message(for: error))"
            }
        }
    }
}
