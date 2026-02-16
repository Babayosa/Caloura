import CoreGraphics
import Foundation

enum PIIType: String, CaseIterable, Codable {
    case email, phone, creditCard, apiKey, ipAddress, ssn
}

struct PIIDetection {
    let type: PIIType
    let text: String
    let boundingBox: CGRect
    let confidence: Float
}

struct PIIDetector {
    // swiftlint:disable force_try
    private static let emailPattern = try! NSRegularExpression(
        pattern: #"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"#
    )
    private static let phonePattern = try! NSRegularExpression(
        pattern: #"\b(?:\+?1[-.]?)?\(?\d{3}\)?[-.]?\d{3}[-.]?\d{4}\b"#
    )
    private static let creditCardPattern = try! NSRegularExpression(
        pattern: #"\b(?:\d[ \-]*?){13,19}\b"#
    )
    private static let apiKeyPattern = try! NSRegularExpression(
        pattern: #"(?:sk|pk|api|key|token|secret|bearer)[-_]?[a-zA-Z0-9]{20,}"#,
        options: .caseInsensitive
    )
    private static let ipAddressPattern = try! NSRegularExpression(
        pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
    )
    private static let ssnPattern = try! NSRegularExpression(
        pattern: #"\b\d{3}[-]?\d{2}[-]?\d{4}\b"#
    )
    // swiftlint:enable force_try

    static func detect(in cgImage: CGImage, types: [PIIType]? = nil) async throws -> [PIIDetection] {
        let observations = try await OCREngine.recognizeTextWithBoundingBoxes(in: cgImage)
        let targetTypes = types ?? PIIType.allCases
        var detections: [PIIDetection] = []
        var seenTexts: Set<String> = []

        for observation in observations {
            let text = observation.text
            let range = NSRange(text.startIndex..., in: text)

            for type in targetTypes {
                let matches = matchesForType(type, text: text, range: range)
                for matchRange in matches {
                    guard let swiftRange = Range(matchRange, in: text) else { continue }
                    let matchedText = String(text[swiftRange])
                    let dedupeKey = "\(type.rawValue):\(matchedText)"
                    guard !seenTexts.contains(dedupeKey) else { continue }

                    if validate(match: matchedText, type: type) {
                        seenTexts.insert(dedupeKey)
                        detections.append(PIIDetection(
                            type: type,
                            text: matchedText,
                            boundingBox: observation.boundingBox,
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

    private static func matchesForType(_ type: PIIType, text: String, range: NSRange) -> [NSRange] {
        let pattern: NSRegularExpression
        switch type {
        case .email: pattern = emailPattern
        case .phone: pattern = phonePattern
        case .creditCard: pattern = creditCardPattern
        case .apiKey: pattern = apiKeyPattern
        case .ipAddress: pattern = ipAddressPattern
        case .ssn: pattern = ssnPattern
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
        let reversed = digits.reversed().map { Int(String($0))! }
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
        let area = Int(digits.prefix(3))!
        let group = Int(digits.dropFirst(3).prefix(2))!
        let serial = Int(digits.suffix(4))!
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
}
