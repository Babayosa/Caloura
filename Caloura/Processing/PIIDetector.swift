import CoreGraphics
import Foundation
import Vision

enum PIIType: String, CaseIterable, Codable {
    case email, phone, creditCard, apiKey, ipAddress, ssn
}

struct PIIDetection {
    let type: PIIType
    /// Always masked. Raw matched text is dropped at construction so it cannot
    /// accidentally land in logs, exports, or in-memory state. Callers that
    /// genuinely need the raw value must re-derive it from the source string +
    /// reported `boundingBox` — an explicit, deliberate access.
    let text: String
    let boundingBox: CGRect
    let confidence: Float

    init(type: PIIType, rawMatch: String, boundingBox: CGRect, confidence: Float) {
        self.type = type
        self.text = PIIDetector.mask(rawMatch, type: type)
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

struct PIIDetectorObservation {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
    let matchBoundingBox: (Range<String.Index>) -> CGRect?
}

private enum PIIPatterns {
    static let email = compile(
        #"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"#
    )
    static let phone = compile(
        #"\b(?:\+?1[-.]?)?\(?\d{3}\)?[-.]?\d{3}[-.]?\d{4}\b"#
    )
    static let creditCard = compile(#"\b(?:\d[ \-]*?){13,19}\b"#)
    static let apiKey = compile(
        #"(?:sk|pk|api|key|token|secret|bearer)[-_]?[a-zA-Z0-9]{20,}"#,
        options: .caseInsensitive
    )
    static let ipAddress = compile(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#)
    static let ssn = compile(#"\b\d{3}[-]?\d{2}[-]?\d{4}\b"#)

    private static func compile(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid PII regex pattern: \(pattern)")
        }
    }
}

struct PIIDetector {
    static func detect(in cgImage: CGImage, types: [PIIType]? = nil) async throws -> [PIIDetection] {
        try await Task.detached(priority: .utility) {
            try performDetection(in: cgImage, types: types)
        }.value
    }

    static func detect(
        in observations: [PIIDetectorObservation],
        types: [PIIType]? = nil
    ) -> [PIIDetection] {
        let targetTypes = types ?? PIIType.allCases
        var detections: [PIIDetection] = []
        var seenMatches: Set<String> = []

        for (observationIndex, observation) in observations.enumerated() {
            let text = observation.text
            let range = NSRange(text.startIndex..., in: text)

            for type in targetTypes {
                let matches = matchesForType(type, text: text, range: range)
                for matchRange in matches {
                    guard let swiftRange = Range(matchRange, in: text) else { continue }
                    let matchedText = String(text[swiftRange])
                    let dedupeKey = [
                        "\(observationIndex)",
                        type.rawValue,
                        "\(matchRange.location)",
                        "\(matchRange.length)"
                    ].joined(separator: ":")
                    guard !seenMatches.contains(dedupeKey) else { continue }

                    if validate(match: matchedText, type: type) {
                        let matchBox = observation.matchBoundingBox(swiftRange) ?? observation.boundingBox
                        seenMatches.insert(dedupeKey)
                        detections.append(PIIDetection(
                            type: type,
                            rawMatch: matchedText,
                            boundingBox: clampNormalizedRect(matchBox),
                            confidence: observation.confidence
                        ))
                    }
                }
            }
        }
        return detections
    }

    /// Test-visible: run regex matching against raw text without OCR.
    static func detectInText(
        _ text: String,
        types: [PIIType]? = nil
    ) -> [(type: PIIType, match: String)] {
        let targetTypes = types ?? PIIType.allCases
        let range = NSRange(text.startIndex..., in: text)
        var results: [(type: PIIType, match: String)] = []
        for type in targetTypes {
            let matches = matchesForType(type, text: text, range: range)
            for matchRange in matches {
                guard let swiftRange = Range(matchRange, in: text) else { continue }
                let matchedText = String(text[swiftRange])
                if validate(match: matchedText, type: type) {
                    results.append((type: type, match: matchedText))
                }
            }
        }
        return results
    }

    private static func performDetection(
        in cgImage: CGImage,
        types: [PIIType]?
    ) throws -> [PIIDetection] {
        var detectorObservations: [PIIDetectorObservation] = []

        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }

            detectorObservations = observations.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return PIIDetectorObservation(
                    text: candidate.string,
                    boundingBox: observation.boundingBox,
                    confidence: candidate.confidence,
                    matchBoundingBox: { range in
                        try? candidate.boundingBox(for: range)?.boundingBox
                    }
                )
            }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        return detect(in: detectorObservations, types: types)
    }

    private static func matchesForType(_ type: PIIType, text: String, range: NSRange) -> [NSRange] {
        let pattern: NSRegularExpression
        switch type {
        case .email: pattern = PIIPatterns.email
        case .phone: pattern = PIIPatterns.phone
        case .creditCard: pattern = PIIPatterns.creditCard
        case .apiKey: pattern = PIIPatterns.apiKey
        case .ipAddress: pattern = PIIPatterns.ipAddress
        case .ssn: pattern = PIIPatterns.ssn
        }
        return pattern.matches(in: text, range: range).map { $0.range }
    }

    private static func validate(match: String, type: PIIType) -> Bool {
        switch type {
        case .creditCard:
            return luhnCheck(match)
        case .ipAddress:
            return validateIPAddress(match)
        case .ssn:
            return validateSSN(match)
        default:
            return true
        }
    }

    static func luhnCheck(_ input: String) -> Bool {
        let digits = input.filter(\.isWholeNumber)
        guard digits.count >= 13, digits.count <= 19 else { return false }

        var sum = 0
        let reversed = digits.reversed().compactMap { Int(String($0)) }
        guard reversed.count == digits.count else { return false }
        for (index, digit) in reversed.enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    private static func validateIPAddress(_ ip: String) -> Bool {
        let octets = ip.split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard let value = Int(octet) else { return false }
            return value >= 0 && value <= 255
        }
    }

    private static func validateSSN(_ ssn: String) -> Bool {
        let digits = ssn.filter(\.isWholeNumber)
        guard digits.count == 9 else { return false }
        guard let area = Int(digits.prefix(3)),
              let group = Int(digits.dropFirst(3).prefix(2)),
              let serial = Int(digits.suffix(4)) else {
            return false
        }
        return area > 0 && area != 666 && area < 900 && group > 0 && serial > 0
    }

    /// Mask PII text for safe display (e.g., "u***@example.com")
    static func mask(_ text: String, type: PIIType) -> String {
        switch type {
        case .email:
            guard let atIndex = text.firstIndex(of: "@") else { return "***" }
            let prefix = String(text.prefix(1))
            let domain = String(text[atIndex...])
            return "\(prefix)***\(domain)"
        case .phone:
            let digits = text.filter(\.isWholeNumber)
            guard digits.count >= 4 else { return "***" }
            return "***-***-\(digits.suffix(4))"
        case .creditCard:
            let digits = text.filter(\.isWholeNumber)
            guard digits.count >= 4 else { return "****" }
            return "****-****-****-\(digits.suffix(4))"
        case .ssn:
            return "***-**-****"
        default:
            guard text.count > 6 else { return "***" }
            return "\(text.prefix(3))***\(text.suffix(3))"
        }
    }

    private static func clampNormalizedRect(_ rect: CGRect) -> CGRect {
        guard !rect.isNull, !rect.isEmpty else { return .zero }
        let standardized = rect.standardized
        let clampedMinX = max(0, min(1, standardized.minX))
        let clampedMinY = max(0, min(1, standardized.minY))
        let clampedMaxX = max(clampedMinX, min(1, standardized.maxX))
        let clampedMaxY = max(clampedMinY, min(1, standardized.maxY))
        return CGRect(
            x: clampedMinX,
            y: clampedMinY,
            width: clampedMaxX - clampedMinX,
            height: clampedMaxY - clampedMinY
        )
    }
}
