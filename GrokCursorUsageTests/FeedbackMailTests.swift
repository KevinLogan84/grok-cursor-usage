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
