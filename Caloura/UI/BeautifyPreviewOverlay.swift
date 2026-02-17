import AppKit
import SwiftUI

@MainActor
final class BeautifyPreviewController {
    static let shared = BeautifyPreviewController()
    private let presenter = SingleWindowPresenter<BeautifyPreviewView>()

    func show(cgImage: CGImage, filePath: URL?) {
        presenter.show(
            config: .init(
                title: "Beautify Screenshot",
                size: CGSize(width: 640, height: 520),
                styleMask: [.titled, .closable, .resizable],
                minSize: CGSize(width: 480, height: 400),
                autosaveName: "CalouraBeautifyPreview"
            )
        ) {
            BeautifyPreviewView(originalImage: cgImage, filePath: filePath)
        }
    }

    func close() {
        presenter.close()
    }
}

struct BeautifyPreviewView: View {
    let originalImage: CGImage
    let filePath: URL?

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
                    Image(decorative: originalImage, scale: 1.0)
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
        let result = await Beautifier.beautify(cgImage: originalImage, theme: selectedTheme)
        previewImage = result
        isProcessing = false
    }

    private func themePreviewGradient(_ theme: BeautifyTheme) -> LinearGradient {
        let colors = theme.gradientColors.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func copyToClipboard(_ cgImage: CGImage) {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        ClipboardManager.copyNSImage(nsImage)
        AppState.shared.statusMessage = "Beautified image copied"
    }

    private func saveImage(_ cgImage: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "beautified-screenshot.png"
        if let fp = filePath {
            let base = fp.deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = "\(base)-beautified.png"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            let success = await Task.detached {
                guard let dest = CGImageDestinationCreateWithURL(
                    url as CFURL, "public.png" as CFString, 1, nil
                ) else { return false }
                CGImageDestinationAddImage(dest, cgImage, nil)
                return CGImageDestinationFinalize(dest)
            }.value

            if success {
                AppState.shared.statusMessage = "Beautified image saved"
            } else {
                AppState.shared.statusMessage = "Failed to save beautified image"
            }
            BeautifyPreviewController.shared.close()
        }
    }
}
