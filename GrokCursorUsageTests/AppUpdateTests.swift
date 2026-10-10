import Foundation
import Testing
@testable import GrokCursorUsage

struct AppUpdateTests {
    @Test
    func semanticVersionComparesNumerically() {
        #expect(AppUpdate.isNewer("1.1", than: "1.0"))
        #expect(AppUpdate.isNewer("v1.2", than: "1.1"))
        #expect(AppUpdate.isNewer("V1.10", than: "1.9"))
        #expect(AppUpdate.isNewer("1.10", than: "1.9"))
        #expect(AppUpdate.isNewer("1.2.1", than: "1.2"))
        #expect(AppUpdate.isNewer("1.0.1", than: "1.0"))
        #expect(AppUpdate.isNewer("2.0", than: "1.9.9"))
        #expect(!AppUpdate.isNewer("1.1", than: "1.1"))
        #expect(!AppUpdate.isNewer("v1.1", than: "1.1"))
        #expect(!AppUpdate.isNewer("v1.1", than: "1.1.0"))
        #expect(!AppUpdate.isNewer("1.1.0", than: "v1.1"))
        #expect(!AppUpdate.isNewer("1.0", than: "1.0.1"))
        #expect(!AppUpdate.isNewer("1.9", than: "1.10"))
        #expect(!AppUpdate.isNewer(" 1.1 ", than: "v1.1"))
        #expect(!AppUpdate.isNewer("latest", than: "1.0"))
        #expect(!AppUpdate.isNewer("v1.2-beta", than: "1.0"))
        #expect(!AppUpdate.isNewer("v1.2", than: "not-a-version"))
        #expect(AppUpdate.versionLabel(for: "v1.2") == "v1.2")
        #expect(AppUpdate.versionLabel(for: "1.2") == "v1.2")
        #expect(AppUpdate.versionLabel(for: "V1.2") == "v1.2")
    }

    @Test
    func updateCheckWaitsADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppUpdate.shouldCheck(lastCheckedAt: nil, now: now))
        #expect(!AppUpdate.shouldCheck(lastCheckedAt: now.addingTimeInterval(-86_399), now: now))
        #expect(AppUpdate.shouldCheck(lastCheckedAt: now.addingTimeInterval(-86_400), now: now))
        #expect(AppUpdate.shouldCheck(lastCheckedAt: now.addingTimeInterval(60), now: now))
        #expect(AppUpdate.waitInterval(lastCheckedAt: nil, now: now) == 0)
        #expect(AppUpdate.waitInterval(lastCheckedAt: now.addingTimeInterval(-3600), now: now) == AppUpdate.checkInterval - 3600)
    }

    @Test
    func latestReleaseRequestSendsNoPersonalData() {
        let request = AppUpdate.makeRequest()
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.url?.query == nil)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/KevinLogan84/grok-cursor-usage/releases/latest")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "GrokCursorUsage")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let blob = (request.allHTTPHeaderFields ?? [:]).values.joined(separator: "\n").lowercased()
        #expect(!blob.contains("@"))
        #expect(!blob.contains("bearer"))
        #expect(!blob.contains("token"))
        let config = AppUpdate.ephemeralConfiguration()
        #expect(config.httpShouldSetCookies == false)
        #expect(config.httpCookieAcceptPolicy == .never)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test
    func latestReleaseJSONPrefersTheMacZip() throws {
        let notice = try #require(AppUpdate.parseRelease(releaseJSON(
            tag: "v1.2",
            body: "Hello from the release.\n",
            html: "https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v1.2",
            assets: [
                ("notes.txt", "https://example.com/notes.txt"),
                ("Grok-Cursor-Usage-macOS.zip", "https://github.com/KevinLogan84/grok-cursor-usage/releases/download/v1.2/Grok-Cursor-Usage-macOS.zip")
            ]
        )))
        #expect(notice == AppUpdateNotice(
            tagName: "v1.2",
            notes: "Hello from the release.\n",
            downloadURL: URL(string: "https://github.com/KevinLogan84/grok-cursor-usage/releases/download/v1.2/Grok-Cursor-Usage-macOS.zip")!
        ))
        #expect(notice.versionLabel == "v1.2")
        #expect(!notice.notes.contains("someone"))
        #expect(!notice.downloadURL.absoluteString.contains("someone"))

        let nullBody = Data(#"{"tag_name":"v2.0","body":null,"html_url":"https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v2.0"}"#.utf8)
        let emptyNotes = try #require(AppUpdate.parseRelease(nullBody))
        #expect(emptyNotes.notes == "")
        #expect(emptyNotes.downloadURL.absoluteString == "https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v2.0")

        let roundTrip = try JSONDecoder().decode(AppUpdateNotice.self, from: JSONEncoder().encode(notice))
        #expect(roundTrip == notice)
    }

    @Test
    func missingZipFallsBackToTheReleasePage() throws {
        let page = try #require(AppUpdate.parseRelease(releaseJSON(
            tag: "v1.3",
            body: "",
            html: "https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v1.3",
            assets: [("Other.zip", "javascript:alert(1)")]
        )))
        #expect(page.downloadURL.absoluteString == "https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v1.3")

        let constructed = try #require(AppUpdate.parseRelease(releaseJSON(
            tag: "v1.4",
            body: "Notes",
            html: "javascript:alert(1)",
            assets: []
        )))
        #expect(constructed.downloadURL.absoluteString == "https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v1.4")
    }

    @Test
    func interpretShowsOnlyANewerReleaseAndStaysQuietOnFailure() throws {
        let newer = releaseJSON(
            tag: "v1.2",
            body: "What’s new",
            html: "https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v1.2",
            assets: [("Grok-Cursor-Usage-macOS.zip", "https://github.com/KevinLogan84/grok-cursor-usage/releases/download/v1.2/Grok-Cursor-Usage-macOS.zip")]
        )
        let available = AppUpdate.interpret(currentVersion: "1.1", statusCode: 200, data: newer)
        guard case .available(let notice) = available else {
            Issue.record("Expected an available update")
            return
        }
        #expect(notice.tagName == "v1.2")
        #expect(notice.notes == "What’s new")
        #expect(!notice.notes.contains("1.1"))

        #expect(AppUpdate.interpret(currentVersion: "1.1", statusCode: 200, data: releaseJSON(
            tag: "v1.1",
            body: "Same",
            html: "https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v1.1",
            assets: []
        )) == .upToDate)
        #expect(AppUpdate.interpret(currentVersion: "1.2", statusCode: 200, data: newer) == .upToDate)
        #expect(AppUpdate.interpret(currentVersion: "1.1", statusCode: 500, data: newer) == .failed)
        #expect(AppUpdate.interpret(currentVersion: "1.1", statusCode: 404, data: Data("nope".utf8)) == .failed)
        #expect(AppUpdate.interpret(currentVersion: "1.1", statusCode: 403, data: Data(#"{"message":"rate limit"}"#.utf8)) == .failed)
        #expect(AppUpdate.interpret(currentVersion: "1.1", statusCode: 200, data: Data()) == .failed)
        #expect(AppUpdate.interpret(currentVersion: "1.1", statusCode: 200, data: Data("{".utf8)) == .failed)
        #expect(AppUpdate.interpret(currentVersion: "1.1", statusCode: 200, data: Data(#"{"message":"Not Found"}"#.utf8)) == .failed)
        #expect(AppUpdate.interpret(currentVersion: "1.1", statusCode: 200, data: releaseJSON(
            tag: "latest",
            body: "nope",
            html: "https://github.com/KevinLogan84/grok-cursor-usage/releases/latest",
            assets: []
        )) == .failed)
        #expect(AppUpdate.interpret(currentVersion: "beta", statusCode: 200, data: newer) == .failed)
    }

    @Test
    func failureKeepsThePreviousNoticeAndAnUpdateClearsIt() {
        let previous = AppUpdateNotice(
            tagName: "v1.2",
            notes: "Cached",
            downloadURL: URL(string: "https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v1.2")!
        )
        #expect(AppUpdate.nextNotice(previous: previous, result: .failed) == previous)
        #expect(AppUpdate.nextNotice(previous: previous, result: .upToDate) == nil)
        let replacement = AppUpdateNotice(
            tagName: "v1.3",
            notes: "Newer",
            downloadURL: previous.downloadURL
        )
        #expect(AppUpdate.nextNotice(previous: previous, result: .available(replacement)) == replacement)
        #expect(AppUpdate.nextNotice(previous: nil, result: .failed) == nil)
        #expect(AppUpdate.noticeToShow(cached: previous, currentVersion: "1.1") == previous)
        #expect(AppUpdate.noticeToShow(cached: previous, currentVersion: "1.2") == nil)
        #expect(AppUpdate.noticeToShow(cached: previous, currentVersion: "1.3") == nil)
        #expect(AppUpdate.noticeToShow(cached: nil, currentVersion: "1.1") == nil)
    }

    @Test
    func marketingVersionIs1_2() {
        #expect(AppUpdate.marketingVersion() == "1.2")
    }
}

private func releaseJSON(
    tag: String,
    body: String,
    html: String,
    assets: [(String, String)]
) -> Data {
    let payload: [String: Any] = [
        "tag_name": tag,
        "name": tag,
        "body": body,
        "html_url": html,
        "draft": false,
        "author": ["login": "someone"],
        "assets": assets.map { name, url in
            ["name": name, "browser_download_url": url, "size": 1] as [String: Any]
        }
    ]
    return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
}
