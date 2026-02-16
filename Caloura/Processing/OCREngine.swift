import Vision

struct OCRObservation {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
}

struct OCREngine {
    /// Recognize text in the given image.
    /// Runs on a background thread with fast recognition settings for better performance.
    static func recognizeText(in cgImage: CGImage) async throws -> String {
        // Offload to background thread to avoid blocking
        return try await Task.detached(priority: .utility) {
            try performOCR(cgImage: cgImage)
        }.value
    }

    /// Recognize text with bounding boxes for each observation.
    /// Uses `.accurate` recognition level for reliable bounding boxes.
    static func recognizeTextWithBoundingBoxes(in cgImage: CGImage) async throws -> [OCRObservation] {
        try await Task.detached(priority: .utility) {
            try performOCRWithBoundingBoxes(cgImage: cgImage)
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

    /// Synchronous OCR with bounding boxes (called from background thread)
    private static func performOCRWithBoundingBoxes(cgImage: CGImage) throws -> [OCRObservation] {
        var results: [OCRObservation] = []

        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }

            results = observations.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRObservation(
                    text: candidate.string,
                    boundingBox: observation.boundingBox,
                    confidence: candidate.confidence
                )
            }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        return results
    }
}
