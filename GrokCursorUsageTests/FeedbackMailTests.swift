import Foundation
import Testing
@testable import GrokCursorUsage

struct FeedbackMailTests {
    @Test
    func feedbackMailtoUsesTheSharedAddress() throws {
        #expect(FeedbackMail.address == "kevinlogan@mail.grokbot.com")
        let url = try #require(FeedbackMail.mailtoURL(
            version: "1.1",
            build: "1",
            systemLine: "macOS: Version 15.0 (Build 24A335)"
        ))
        let raw = url.absoluteString
        #expect(raw.hasPrefix("mailto:\(FeedbackMail.address)?"))
        #expect(raw.components(separatedBy: FeedbackMail.address).count == 2)
        #expect(queryNames(url) == ["subject", "body"])
        #expect(queryValue(url, "subject") == "Grok & Cursor Usage feedback")
    }

    @Test
    func feedbackMailtoEncodesSubjectAndBody() throws {
        let systemLine = "macOS: line 1\nline & 2"
        let body = FeedbackMail.body(version: "1.0 & 2", build: "3=4", systemLine: systemLine)
        let url = try #require(FeedbackMail.mailtoURL(
            version: "1.0 & 2",
            build: "3=4",
            systemLine: systemLine
        ))
        let raw = url.absoluteString
        #expect(raw.contains("subject=Grok%20%26%20Cursor%20Usage%20feedback"))
        #expect(raw.contains("%0A"))
        #expect(raw.contains("%26"))
        #expect(!raw.contains(" "))
        #expect(!raw.contains("\n"))
        #expect(raw.filter { $0 == "&" }.count == 1)
        #expect(queryValue(url, "subject") == FeedbackMail.subject)
        #expect(queryValue(url, "body") == body)
    }

    @Test
    func feedbackBodyIsOnlyVersionBuildAndSystem() throws {
        let version = "1.1"
        let build = "1"
        let systemLine = "macOS: Version 15.0 (Build 24A335)"
        let body = FeedbackMail.body(version: version, build: build, systemLine: systemLine)
        #expect(body == "App version: 1.1 (1)\nmacOS: Version 15.0 (Build 24A335)\n\n")
        let lowered = body.lowercased()
        for word in ["token", "bearer", "cookie", "account", "usage", "@", "%"] {
            #expect(!lowered.contains(word))
        }

        let url = try #require(FeedbackMail.currentMailtoURL())
        let liveBody = try #require(queryValue(url, "body"))
        let info = Bundle.main.infoDictionary
        let liveVersion = nonEmpty(info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let liveBuild = nonEmpty(info?["CFBundleVersion"] as? String) ?? "unknown"
        #expect(liveBody == FeedbackMail.body(
            version: liveVersion,
            build: liveBuild,
            systemLine: FeedbackMail.currentSystemLine
        ))
        #expect(FeedbackMail.currentSystemLine.hasPrefix("macOS: "))
        #expect(!liveBody.contains("@"))
        #expect(!liveBody.lowercased().contains("token"))
        #expect(!liveBody.lowercased().contains("cookie"))
        #expect(!liveBody.lowercased().contains("account"))
        #expect(queryValue(url, "subject") == FeedbackMail.subject)
        #expect(queryNames(url) == ["subject", "body"])
    }

    @Test
    func mailtoHandlerKindIsBrowserMailAppOrMissing() {
        let browsers = [
            "com.google.Chrome",
            "com.apple.Safari",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "company.thebrowser.Browser",
        ]
        #expect(FeedbackMail.browserBundleIdentifiers == Set(browsers))
        for bundleID in browsers {
            #expect(FeedbackMail.handlerKind(bundleIdentifier: bundleID) == .browser)
        }
        #expect(FeedbackMail.handlerKind(bundleIdentifier: " com.apple.Safari ") == .browser)
        #expect(FeedbackMail.shouldOfferCopyFallback(.browser))

        let mailApps = [
            "com.apple.mail",
            "com.microsoft.Outlook",
            "com.readdle.smartemail-Mac",
            "com.example.Mailer",
        ]
        for bundleID in mailApps {
            #expect(FeedbackMail.handlerKind(bundleIdentifier: bundleID) == .mailApp)
            #expect(!FeedbackMail.browserBundleIdentifiers.contains(bundleID))
        }
        #expect(!FeedbackMail.shouldOfferCopyFallback(.mailApp))

        let missingIdentifiers: [String?] = [nil, "", "   "]
        for missing in missingIdentifiers {
            #expect(FeedbackMail.handlerKind(bundleIdentifier: missing) == .missing)
        }
        #expect(FeedbackMail.shouldOfferCopyFallback(.missing))
    }

    @Test
    func missingMailtoApplicationOffersCopyFallback() {
        #expect(FeedbackMail.handlerKind(
            applicationURL: nil,
            bundleIdentifier: { _ in "com.apple.mail" }
        ) == .missing)

        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let chromeKind = FeedbackMail.handlerKind(applicationURL: chrome, bundleIdentifier: { _ in "com.google.Chrome" })
        #expect(chromeKind == .browser)
        #expect(FeedbackMail.shouldOfferCopyFallback(chromeKind))

        let mail = URL(fileURLWithPath: "/System/Applications/Mail.app")
        #expect(FeedbackMail.handlerKind(applicationURL: mail, bundleIdentifier: { _ in "com.apple.mail" }) == .mailApp)
        #expect(FeedbackMail.handlerKind(applicationURL: mail, bundleIdentifier: { _ in "com.microsoft.Outlook" }) == .mailApp)
        #expect(FeedbackMail.handlerKind(applicationURL: mail, bundleIdentifier: { _ in nil }) == .missing)
        #expect(FeedbackMail.handlerKind(applicationURL: mail, bundleIdentifier: { _ in "  " }) == .missing)

        let absent = URL(fileURLWithPath: "/Applications/DoesNotExist.app")
        #expect(FeedbackMail.handlerKind(applicationURL: absent) == .missing)
    }

    @Test
    func feedbackFallbackCopyNamesTheAddressAndHowToChangeTheDefault() {
        #expect(FeedbackMail.copyAddressButtonTitle == "Copy Address")
        #expect(FeedbackMail.openAnywayButtonTitle == "Open Mail Draft Anyway")
        let note = FeedbackMail.macHandlerExplanation
        #expect(!note.contains("\n"))
        #expect(note.contains("default email app seems to be a browser"))
        #expect(note.contains("Mail > Settings > General > Default email reader"))
        #expect(FeedbackMail.handlerExplanation == note)
        #expect(!FeedbackMail.iosHandlerExplanation.contains("\n"))
        #expect(FeedbackMail.iosHandlerExplanation.contains("Copy the address"))
        #expect(!FeedbackMail.iosHandlerExplanation.contains("Default email reader"))
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

private func queryNames(_ url: URL) -> [String] {
    guard let query = url.absoluteString.split(separator: "?", maxSplits: 1).last else { return [] }
    return query.split(separator: "&").compactMap { pair in
        pair.split(separator: "=", maxSplits: 1).first.map {
            String($0).removingPercentEncoding ?? String($0)
        }
    }
}

private func queryValue(_ url: URL, _ name: String) -> String? {
    guard let query = url.absoluteString.split(separator: "?", maxSplits: 1).last else { return nil }
    for pair in query.split(separator: "&") {
        let bits = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard bits.count == 2, bits[0].removingPercentEncoding == name else { continue }
        return bits[1].removingPercentEncoding
    }
    return nil
}
