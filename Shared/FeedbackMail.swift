import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Opens a draft in the user's mail app. The app never sends the message.
enum FeedbackMail {
    /// Which app would open a `mailto:` link.
    enum Handler: Equatable, Sendable {
        /// A mail app is registered. Open the draft directly.
        case mailApp
        /// A browser is registered, so opening the link would show a browser tab.
        case browser
        /// No app is registered, or its bundle identifier cannot be read.
        case missing
    }

    static let address = "kevinlogan@mail.grokbot.com"
    static let subject = "Grok & Cursor Usage feedback"
    static let buttonTitle = "Send Feedback"
    static let buttonHint = "Opens a mail draft. Nothing is sent until you send it."
    static let copyAddressButtonTitle = "Copy Address"
    static let openAnywayButtonTitle = "Open Mail Draft Anyway"

    /// One sentence. Shown when the Mac would open a browser, or has no mail handler.
    static let macHandlerExplanation = "This Mac’s default email app seems to be a browser. Change it in Mail > Settings > General > Default email reader."

    /// Shown on iPhone when a draft cannot be opened.
    static let iosHandlerExplanation = "A mail draft couldn’t be opened. Copy the address, or try Open Mail Draft Anyway."

    /// Bundle identifiers that open a mailto link as a browser tab.
    static let browserBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
    ]

    static var handlerExplanation: String {
        #if os(macOS)
        return macHandlerExplanation
        #else
        return iosHandlerExplanation
        #endif
    }

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

    /// Classifies a bundle identifier from the app `NSWorkspace.urlForApplication(toOpen:)` returns.
    /// Nil or blank means the handler is missing. Known browser identifiers are browsers.
    /// Anything else is treated as a mail app and opened directly.
    static func handlerKind(bundleIdentifier: String?) -> Handler {
        let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !identifier.isEmpty else { return .missing }
        if browserBundleIdentifiers.contains(identifier) {
            return .browser
        }
        return .mailApp
    }

    /// Classifies the app URL from `NSWorkspace.urlForApplication(toOpen:)`.
    /// Pass `nil` when that lookup finds no app.
    static func handlerKind(
        applicationURL: URL?,
        bundleIdentifier: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }
    ) -> Handler {
        guard let applicationURL else { return .missing }
        return handlerKind(bundleIdentifier: bundleIdentifier(applicationURL))
    }

    static func shouldOfferCopyFallback(_ handler: Handler) -> Bool {
        switch handler {
        case .mailApp:
            return false
        case .browser, .missing:
            return true
        }
    }

    #if os(macOS)
    /// Looks up the default app for the feedback draft and classifies it.
    @MainActor
    static func currentHandlerKind() -> Handler {
        guard let mailtoURL = currentMailtoURL() else { return .missing }
        let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: mailtoURL)
        return handlerKind(applicationURL: applicationURL)
    }

    /// The menu panel has to be key or the fallback popover will not appear.
    /// The status item sits at the same level, so the wide borderless panel is the menu.
    @MainActor
    static func prepareToPresentFallback() {
        NSApp.activate()
        let panel = NSApp.windows.first {
            $0.isVisible
                && $0.level == .statusBar
                && $0.styleMask.contains(.borderless)
                && $0.frame.width > 200
        }
        panel?.makeKey()
    }
    #endif

    /// Shows a draft in the default mail app, even when that app is a browser.
    /// Returns whether the system accepted the open. The app never sends the message.
    @MainActor
    @discardableResult
    static func openDraft() async -> Bool {
        guard let url = currentMailtoURL() else { return false }
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #elseif os(iOS)
        return await UIApplication.shared.open(url, options: [:])
        #endif
    }

    /// Opens a draft when a mail app will handle it. Otherwise asks the caller to show the address.
    @MainActor
    static func performSend(presentFallback: @escaping @MainActor () -> Void) async {
        #if os(macOS)
        if shouldOfferCopyFallback(currentHandlerKind()) {
            prepareToPresentFallback()
            presentFallback()
        } else {
            await openDraft()
        }
        #elseif os(iOS)
        guard let url = currentMailtoURL(), UIApplication.shared.canOpenURL(url) else {
            presentFallback()
            return
        }
        let opened = await UIApplication.shared.open(url, options: [:])
        if !opened {
            presentFallback()
        }
        #endif
    }

    @MainActor
    @discardableResult
    static func copyAddressToPasteboard() -> Bool {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(address, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = address
        return true
        #endif
    }

    private static func bundleValue(_ bundle: Bundle, _ key: String) -> String {
        let value = bundle.infoDictionary?[key] as? String
        guard let value, !value.isEmpty else { return "unknown" }
        return value
    }
}

/// Send Feedback button. A mail app opens a draft. A browser, or no handler, shows the address.
struct SendFeedbackButton: View {
    /// The Guide is a normal window, so a sheet fits. The menu is a borderless panel, so a popover
    /// stays attached to the button. iPhone always uses a sheet.
    var presentsAsSheet = false

    @State private var showsFallback = false

    var body: some View {
        presented(
            Button(FeedbackMail.buttonTitle, action: send)
                .accessibilityHint(FeedbackMail.buttonHint)
        )
    }

    private func send() {
        #if os(iOS)
        // The flag only chooses the Mac presentation. iPhone always sheets.
        _ = presentsAsSheet
        #endif
        Task {
            await FeedbackMail.performSend {
                showsFallback = true
            }
        }
    }

    @ViewBuilder
    private func presented<V: View>(_ button: V) -> some View {
        #if os(iOS)
        button.sheet(isPresented: $showsFallback) {
            ScrollView {
                FeedbackAddressFallback(onDismiss: { showsFallback = false })
            }
            .scrollBounceBehavior(.basedOnSize)
            .presentationDetents([.height(400), .medium])
            .presentationDragIndicator(.visible)
        }
        #else
        if presentsAsSheet {
            button.sheet(isPresented: $showsFallback) {
                FeedbackAddressFallback(onDismiss: { showsFallback = false })
            }
        } else {
            button.popover(isPresented: $showsFallback) {
                FeedbackAddressFallback(onDismiss: { showsFallback = false })
            }
        }
        #endif
    }
}

private struct FeedbackFallbackWidth: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        return content
            .frame(width: 320, alignment: .leading)
            .fixedSize(horizontal: true, vertical: true)
        #else
        return content.frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }
}

private struct FeedbackAddressFallback: View {
    var onDismiss: () -> Void

    @Environment(\.menuScale) private var menuScale
    @State private var didCopy = false
    @State private var copyGeneration = 0
    @State private var isOpening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(FeedbackMail.address)
                .font(addressFont)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .accessibilityLabel("Email address")
                .accessibilityValue(FeedbackMail.address)

            Text(FeedbackMail.handlerExplanation)
                .font(explanationFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                Button(action: copyAddress) {
                    Label(
                        didCopy ? "Copied" : FeedbackMail.copyAddressButtonTitle,
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                    .font(buttonFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(didCopy ? "Copied" : FeedbackMail.copyAddressButtonTitle)
                .accessibilityHint("Copies \(FeedbackMail.address)")

                Button(action: openAnyway) {
                    Label(FeedbackMail.openAnywayButtonTitle, systemImage: "envelope")
                        .font(buttonFont)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isOpening)
                .accessibilityHint("Opens a mail draft. Nothing is sent until you send it.")
            }
            .buttonBorderShape(.automatic)
            .focusEffectDisabled(false)
        }
        .padding(16)
        .modifier(FeedbackFallbackWidth())
        .accessibilityElement(children: .contain)
    }

    private var addressFont: Font {
        #if os(macOS)
        return MenuMetrics.font(15, scale: menuScale, weight: .semibold)
        #else
        return Font.body.weight(.semibold)
        #endif
    }

    private var explanationFont: Font {
        #if os(macOS)
        return MenuMetrics.font(13, scale: menuScale)
        #else
        return Font.footnote
        #endif
    }

    private var buttonFont: Font {
        #if os(macOS)
        return MenuMetrics.font(13, scale: menuScale, weight: .semibold)
        #else
        return Font.body.weight(.semibold)
        #endif
    }

    private func copyAddress() {
        guard FeedbackMail.copyAddressToPasteboard() else { return }
        copyGeneration += 1
        didCopy = true
        AccessibilityNotification.Announcement("Copied").post()
        let generation = copyGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard generation == copyGeneration else { return }
            didCopy = false
        }
    }

    private func openAnyway() {
        guard !isOpening else { return }
        isOpening = true
        Task { @MainActor in
            let opened = await FeedbackMail.openDraft()
            isOpening = false
            if opened {
                onDismiss()
            }
        }
    }
}
