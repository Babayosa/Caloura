import Vision

struct OCREngine {
    /// Recognize text in the given image.
    /// Runs on a background thread with fast recognition settings for better performance.
    static func recognizeText(in cgImage: CGImage) async throws -> String {
        // Offload to background thread to avoid blocking
        return try await Task.detached(priority: .utility) {
            try performOCR(cgImage: cgImage)
        }.value
    }

    /// Synchronous OCR implementation (called from background thread)
    private static func performOCR(cgImage: CGImage) throws -> String {
        var recognizedText = ""

        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }

            recognizedText = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }.joined(separator: "\n")
        }

        // Use fast recognition for better performance
        // .accurate adds 3-5x latency with marginal quality improvement for screenshots
        request.recognitionLevel = .fast

        // Disable expensive post-processing options
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        return recognizedText
    }
}
