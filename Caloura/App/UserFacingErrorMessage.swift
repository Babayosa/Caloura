import AppKit

enum UserFacingErrorMessage {
    static func message(for error: Error) -> String {
        message(for: ErrorSnapshot(error: error))
    }

    static func message(for snapshot: UpdateErrorSnapshot) -> String {
        message(for: ErrorSnapshot(
            domain: snapshot.domain,
            code: snapshot.code,
            localizedDescription: snapshot.localizedDescription
        ))
    }

    private static func message(for snapshot: ErrorSnapshot) -> String {
        if isNetworkError(snapshot) {
            return "Could not connect. Check your internet connection and try again."
        }

        if isClipboardError(snapshot) {
            return "Could not copy to the clipboard. Try again."
        }

        let message = snapshot.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return "Something went wrong. Try again."
        }
        return message
    }

    private static func isNetworkError(_ snapshot: ErrorSnapshot) -> Bool {
        guard snapshot.domain == NSURLErrorDomain else { return false }
        switch snapshot.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired,
             NSURLErrorCannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }

    private static func isClipboardError(_ snapshot: ErrorSnapshot) -> Bool {
        snapshot.domain == NSPasteboard.PasteboardType.string.rawValue
            || snapshot.domain.localizedCaseInsensitiveContains("pasteboard")
            || snapshot.localizedDescription.localizedCaseInsensitiveContains("pasteboard")
            || snapshot.localizedDescription.localizedCaseInsensitiveContains("clipboard")
    }

    private struct ErrorSnapshot {
        let domain: String
        let code: Int
        let localizedDescription: String

        init(error: Error) {
            let nsError = error as NSError
            self.domain = nsError.domain
            self.code = nsError.code
            self.localizedDescription = nsError.localizedDescription
        }

        init(domain: String, code: Int, localizedDescription: String) {
            self.domain = domain
            self.code = code
            self.localizedDescription = localizedDescription
        }
    }
}
