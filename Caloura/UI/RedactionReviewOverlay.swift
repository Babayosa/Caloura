import AppKit
import SwiftUI

@MainActor
final class RedactionReviewController {
    static let shared = RedactionReviewController()
    private let presenter = SingleWindowPresenter<RedactionReviewView>()

    func show(screenshot: ProcessedScreenshot, detections: [PIIDetection]) {
        presenter.show(
            config: .init(
                title: "Review Detected PII",
                size: CGSize(width: 600, height: 500),
                styleMask: [.titled, .closable, .resizable],
                minSize: CGSize(width: 480, height: 400),
                autosaveName: "CalouraRedactionReview"
            )
        ) {
            RedactionReviewView(
                screenshot: screenshot,
                detections: detections
            )
        }
    }

    func close() {
        presenter.close()
    }
}

struct RedactionReviewView: View {
    let screenshot: ProcessedScreenshot
    let detections: [PIIDetection]

    @State private var selectedIndices: Set<Int>
    @State private var redactedImage: CGImage?
    @State private var isRedacting = false
    @State private var hasRedacted = false

    init(screenshot: ProcessedScreenshot, detections: [PIIDetection]) {
        self.screenshot = screenshot
        self.detections = detections
        // All detections selected by default
        _selectedIndices = State(initialValue: Set(detections.indices))
    }

    var body: some View {
        VStack(spacing: 12) {
            // Preview
            Image(decorative: redactedImage ?? screenshot.cgImage, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Detection list
            if !detections.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(detections.enumerated()), id: \.offset) { index, detection in
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { selectedIndices.contains(index) },
                                    set: { isSelected in
                                        if isSelected {
                                            selectedIndices.insert(index)
                                        } else {
                                            selectedIndices.remove(index)
                                        }
                                    }
                                )) {
                                    HStack(spacing: 6) {
                                        piiTypeBadge(detection.type)
                                        Text(PIIDetector.mask(detection.text, type: detection.type))
                                            .font(.system(.body, design: .monospaced))
                                            .lineLimit(1)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 120)
            }

            // Actions
            HStack {
                Button("Cancel") {
                    RedactionReviewController.shared.close()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if hasRedacted {
                    Button("Done") {
                        Task { await commitAndClose() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Redact All") {
                        selectedIndices = Set(detections.indices)
                        Task { await applyRedaction() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(detections.isEmpty)

                    Button("Redact Selected (\(selectedIndices.count))") {
                        Task { await applyRedaction() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIndices.isEmpty || isRedacting)
                }
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 400)
    }

    private func applyRedaction() async {
        isRedacting = true
        let regions = selectedIndices.map { detections[$0].boundingBox }
        let result = await RedactionEngine.redact(cgImage: screenshot.cgImage, regions: regions)
        redactedImage = result
        isRedacting = false
        hasRedacted = true
    }

    private func commitAndClose() async {
        guard let redactedImage else { return }

        do {
            _ = try await ScreenshotArtifactCoordinator.shared.saveDerivedCapture(
                redactedImage,
                basedOn: screenshot,
                suggestedSuffix: "redacted"
            )
        } catch is CancellationError {
            AppState.shared.statusMessage = "Redaction save cancelled"
            return
        } catch {
            AppState.shared.statusMessage = "Overwrite failed: \(error.localizedDescription)"
            return
        }

        let size = NSSize(width: redactedImage.width, height: redactedImage.height)
        let nsImage = NSImage(cgImage: redactedImage, size: size)
        do {
            try ClipboardManager.copyNSImage(nsImage)
        } catch {
            AppState.shared.statusMessage = error.localizedDescription
            return
        }

        AppState.shared.statusMessage = "Redacted \(selectedIndices.count) item(s)"
        RedactionReviewController.shared.close()
    }

    private func piiTypeBadge(_ type: PIIType) -> some View {
        Text(type.rawValue.capitalized)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(piiTypeColor(type).opacity(0.15))
            .foregroundStyle(piiTypeColor(type))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func piiTypeColor(_ type: PIIType) -> Color {
        switch type {
        case .email: return .blue
        case .phone: return .green
        case .creditCard: return .red
        case .apiKey: return .orange
        case .ipAddress: return .purple
        case .ssn: return .red
        }
    }
}
