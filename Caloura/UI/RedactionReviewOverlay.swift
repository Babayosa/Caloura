import AppKit
import SwiftUI

@MainActor
final class RedactionReviewController {
    static let shared = RedactionReviewController()
    private let presenter = SingleWindowPresenter<RedactionReviewView>()

    var debugWindow: NSWindow? {
        presenter.window
    }

    func show(screenshot: ProcessedScreenshot, detections: [PIIDetection]) {
        presenter.show(
            config: .init(
                title: "Review Detected PII",
                size: CGSize(width: 600, height: 500),
                styleMask: [.titled, .closable, .resizable],
                minSize: CGSize(width: 480, height: 400),
                autosaveName: "CalouraRedactionReview",
                sharingType: .none
            ),
            activateApp: true
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

@MainActor
@Observable
final class RedactionReviewModel {
    private(set) var redactedImage: CGImage?
    private(set) var isRedacting = false
    private(set) var hasRedacted = false

    @ObservationIgnored private let redact: (CGImage, [CGRect]) async -> CGImage

    init(
        redact: @escaping (CGImage, [CGRect]) async -> CGImage = {
            await RedactionEngine.redact(cgImage: $0, regions: $1)
        }
    ) {
        self.redact = redact
    }

    func applyRedaction(source: CGImage, regions: [CGRect]) async {
        isRedacting = true
        defer { isRedacting = false }
        let result = await redact(source, regions)
        guard !Task.isCancelled else { return }
        redactedImage = result
        hasRedacted = true
    }
}

struct RedactionReviewView: View {
    let screenshot: ProcessedScreenshot
    let detections: [PIIDetection]

    @State private var selectedIndices: Set<Int>
    @State private var model = RedactionReviewModel()

    init(screenshot: ProcessedScreenshot, detections: [PIIDetection]) {
        self.screenshot = screenshot
        self.detections = detections
        // All detections selected by default
        _selectedIndices = State(initialValue: Set(detections.indices))
    }

    var body: some View {
        VStack(spacing: 12) {
            // Preview
            Image(decorative: model.redactedImage ?? screenshot.cgImage, scale: 1.0)
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
                                        Text(detection.text)
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

                if model.hasRedacted {
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
                    .disabled(detections.isEmpty || model.isRedacting)

                    Button("Redact Selected (\(selectedIndices.count))") {
                        Task { await applyRedaction() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIndices.isEmpty || model.isRedacting)
                }
            }

            if model.isRedacting {
                ProgressView("Applying redaction...")
                    .controlSize(.small)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 400)
    }

    private func applyRedaction() async {
        let regions = selectedIndices.map { detections[$0].boundingBox }
        await model.applyRedaction(source: screenshot.cgImage, regions: regions)
    }

    private func commitAndClose() async {
        guard let redactedImage = model.redactedImage else { return }

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
            AppState.shared.statusMessage = "Save failed: \(UserFacingErrorMessage.message(for: error))"
            return
        }

        let size = NSSize(width: redactedImage.width, height: redactedImage.height)
        let nsImage = NSImage(cgImage: redactedImage, size: size)
        do {
            try ClipboardManager.copyNSImage(nsImage)
        } catch {
            AppState.shared.statusMessage = UserFacingErrorMessage.message(for: error)
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
