import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Opens a draft in the user's mail app. The app never sends the message.
enum FeedbackMail {
    static let address = "kevinlogan@mail.grokbot.com"
    static let subject = "Grok & Cursor Usage feedback"
    static let buttonTitle = "Send Feedback"

    static var currentSystemLine: String {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        #if os(macOS)
        return "macOS: \(version)"
        #elseif os(iOS)
        return "iOS: \(version)"
        #else
        return "System: \(version)"
        #endif
    }

    static func body(version: String, build: String, systemLine: String) -> String {
        "App version: \(version) (\(build))\n\(systemLine)\n\n"
    }

    /// `mailto:` URL for a draft. Subject and body are percent-encoded with `URLComponents`.
    /// The address, version, build, and system line are the only fields. No usage or account data.
    static func mailtoURL(version: String, build: String, systemLine: String) -> URL? {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body(version: version, build: build, systemLine: systemLine))
        ]
        // URLComponents percent-encodes the query. Mailto treats "+" as a plus, not a space.
        guard let encoded = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%20")
        else { return nil }
        return URL(string: "mailto:\(address)?\(encoded)")
    }

    static func currentMailtoURL(bundle: Bundle = .main) -> URL? {
        mailtoURL(
            version: bundleValue(bundle, "CFBundleShortVersionString"),
            build: bundleValue(bundle, "CFBundleVersion"),
            systemLine: currentSystemLine
        )
    }

    /// Shows a draft in the default mail app. Returns without sending anything.
    @MainActor
    static func openDraft() {
        guard let url = currentMailtoURL() else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        #endif
    }

    private static func bundleValue(_ bundle: Bundle, _ key: String) -> String {
        let value = bundle.infoDictionary?[key] as? String
        guard let value, !value.isEmpty else { return "unknown" }
        return value
    }
}
