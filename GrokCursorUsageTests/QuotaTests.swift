import AppKit
import Foundation
import SwiftUI
import Testing
import UserNotifications
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GrokCursorUsage

struct QuotaTests {
    @Test
    func cursorQuotaParsesModelPools() throws {
        let json = """
        {
          "billingCycleEnd": 1789583069000,
          "planUsage": {
            "autoPercentUsed": 10.523,
            "apiPercentUsed": 22.728
          }
        }
        """.data(using: .utf8)!
        let now = Date(timeIntervalSince1970: 1_787_433_600)
        let bars = try #require(QuotaParsing.cursorBars(from: json, now: now))
        #expect(bars.count == 2)
        #expect(bars[0].title == "Cursor Auto")
        #expect(bars[0].subtitle == "Auto")
        #expect(bars[0].usedText == "11% used")
        #expect(bars[1].title == "Cursor API")
        #expect(bars[1].subtitle == "API models")
        #expect(bars[1].usedText == "23% used")
        #expect(bars[0].detail.contains("Resets"))
        #expect(bars[0].detail.contains("left"))
    }

    @Test
    func cursorPlanNameTitlesBothPoolsAndDropsAMissingPool() throws {
        let ultra = """
        {
          "membershipType": "ultra",
          "planUsage": { "autoPercentUsed": 4, "apiPercentUsed": 80 }
        }
        """.data(using: .utf8)!
        let both = try #require(QuotaParsing.cursorBars(from: ultra))
        #expect(both.map(\.title) == ["Cursor Ultra", "Cursor Ultra"])
        #expect(both.map(\.subtitle) == ["Auto", "API models"])

        let autoOnly = """
        { "membershipType": "pro", "planUsage": { "autoPercentUsed": 12 } }
        """.data(using: .utf8)!
        let one = try #require(QuotaParsing.cursorBars(from: autoOnly))
        #expect(one.map(\.kind) == [.cursorModels])
        #expect(one[0].title == "Cursor Pro")
    }

    @Test
    func superGrokParsesWeeklyTotalAndCountdown() throws {
        let json = """
        {
          "config": {
            "creditUsagePercent": 15.0,
            "currentPeriod": {
              "end": "2026-08-23T18:22:26.517846+00:00"
            }
          }
        }
        """.data(using: .utf8)!
        let now = QuotaParsing.parseISODate("2026-08-22T21:28:00Z")!
        let bar = try #require(QuotaParsing.superGrokBar(from: json, now: now))
        #expect(bar.kind == .superGrok)
        #expect(bar.title == "Grok")
        #expect(bar.usedText == "15% used")
        #expect(bar.subtitle == "Weekly usage")
        #expect(bar.detail.contains("Resets"))
        #expect(bar.detail.contains("left"))
        #expect(bar.periodEnd == QuotaParsing.parseISODate("2026-08-23T18:22:26.517846+00:00"))
    }

    @Test
    func grokPlanNameComesFromTheAccountAndAMissingPlanIsOmitted() throws {
        let heavy = """
        { "subscriptionTier": "SUPERGROK_HEAVY", "creditUsagePercent": 8 }
        """.data(using: .utf8)!
        let heavyBar = try #require(QuotaParsing.superGrokBar(from: heavy))
        #expect(heavyBar.title == "SuperGrok Heavy")

        let standard = """
        { "planName": "SuperGrok", "creditUsagePercent": 3 }
        """.data(using: .utf8)!
        let standardBar = try #require(QuotaParsing.superGrokBar(from: standard))
        #expect(standardBar.title == "SuperGrok")

        let unsubscribed = """
        { "hasSubscription": false }
        """.data(using: .utf8)!
        #expect(QuotaParsing.superGrokBar(from: unsubscribed) == nil)

        let botOff = """
        { "enabled": false, "usagePercent": 10 }
        """.data(using: .utf8)!
        #expect(QuotaParsing.grokBotBar(from: botOff) == nil)
        #expect(QuotaParsing.grokBotHasNoAllowance(botOff))
        #expect(!QuotaParsing.grokBotHasNoAllowance(Data("{}".utf8)))
    }

    @Test
    func superGrokTreatsMissingPercentAsZeroAfterWeeklyReset() throws {
        let json = """
        {
          "config": {
            "isUnifiedBillingUser": true,
            "billingPeriodStart": "2026-08-23T18:22:26.517846+00:00",
            "billingPeriodEnd": "2026-08-30T18:22:26.517846+00:00",
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-08-23T18:22:26.517846+00:00",
              "end": "2026-08-30T18:22:26.517846+00:00"
            }
          }
        }
        """.data(using: .utf8)!
        let now = QuotaParsing.parseISODate("2026-08-23T21:10:00Z")!
        let bar = try #require(QuotaParsing.superGrokBar(from: json, now: now))
        #expect(bar.usedText == "0% used")
        #expect(bar.state == .ready)
        #expect(bar.detail.contains("Resets Aug 30"))
    }

    @Test @MainActor
    func grokSignInDefaultsToTheCLIWithoutGrokApp() {
        let suite = "com.grokcursorusage.tests.grokSource.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GrokSignInSourceStore(defaults: defaults)
        #expect(store.source == .cli)
        #expect(!store.source.usesGrokApp)
        store.source = .cliAndGrokApp
        #expect(GrokSignInSource.current(defaults) == .cliAndGrokApp)
        #expect(GrokSignInSourceStore(defaults: defaults).source.usesGrokApp)
    }

    @Test
    func grokUnavailableCopyNeverAsksForCLILoginWhenSessionExists() {
        let superGrok = QuotaUnavailableCopy.superGrok(hasGrokBilling: false, hasGrokSession: true)
        #expect(superGrok == QuotaUnavailableCopy.grokUnavailable)
        #expect(!superGrok.lowercased().contains("grok login"))
        #expect(
            QuotaUnavailableCopy.superGrok(hasGrokBilling: false, hasGrokSession: false)
                == QuotaUnavailableCopy.grokNeedsSignIn
        )
    }

    @Test
    func grokCLIAuthReadsGROKHomeAndExplicitJSONPath() {
        let home = URL(fileURLWithPath: "/tmp/hotspot-grok-home")
        let urls = GrokCLIAuth.authFileURLs(
            environment: [
                "GROK_HOME": "/opt/grok-home",
                "GROK_AUTH_JSON": "/tmp/custom-auth.json"
            ],
            userHome: home
        )
        #expect(urls.map(\.path) == ["/tmp/custom-auth.json", "/opt/grok-home/auth.json"])
    }

    @Test
    func safariBinaryCookiesRoundTripKeepsNamesNotHostsOutsideGrok() throws {
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let live = SafariCookie(
            domain: ".grok.com",
            name: "sso",
            path: "/",
            value: "session-token",
            expiry: now.addingTimeInterval(3_600)
        )
        let xai = SafariCookie(
            domain: "accounts.x.ai",
            name: "sso-rw",
            path: "/",
            value: "refresh-token",
            expiry: now.addingTimeInterval(3_600)
        )
        let other = SafariCookie(
            domain: ".example.com",
            name: "sid",
            path: "/",
            value: "nope",
            expiry: now.addingTimeInterval(3_600)
        )
        let parsed = SafariBinaryCookies.parse(SafariBinaryCookies.encode([live, xai, other]))
        #expect(parsed.map(\.name) == ["sso", "sso-rw", "sid"])
        #expect(parsed.map(\.domain) == [".grok.com", "accounts.x.ai", ".example.com"])
        #expect(GrokAppSession.isAllowedHost(".grok.com"))
        #expect(GrokAppSession.isAllowedHost("accounts.x.ai"))
        #expect(!GrokAppSession.isAllowedHost("example.com"))
        let header = try #require(GrokAppSession.cookieHeader(from: [live, xai]))
        #expect(header.contains("sso="))
        #expect(header.contains("sso-rw="))
    }

    @Test
    func safariBinaryCookiesParsesPageSizesNotOffsets() throws {
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let expiry = now.addingTimeInterval(86_400)
        func cookie(domain: String, name: String) -> SafariCookie {
            SafariCookie(domain: domain, name: name, path: "/", value: "x", expiry: expiry)
        }
        // Classic cook: N big-endian ints after magic+pageCount are page sizes.
        // Pages sit back-to-back after the 8+4*N header. Grok.app's file uses
        // this layout. Reading those ints as offsets finds no cookies.
        let data = SafariBinaryCookies.encode(pages: [
            [cookie(domain: ".grok.com", name: "sso")],
            [cookie(domain: ".grok.com", name: "sso-rw")],
            [cookie(domain: ".grok.com", name: "cf_clearance")],
            [cookie(domain: ".grok.com", name: "grok_device_id")],
            [cookie(domain: "accounts.x.ai", name: "gb_anon_id")],
        ])
        #expect(data.starts(with: Data("cook".utf8)))
        let pageCount = binarycookiesInt32BE(data, 4)
        #expect(pageCount == 5)
        let headerSize = 8 + pageCount * 4
        var sizes: [Int] = []
        var sizeSum = 0
        for index in 0..<pageCount {
            let size = binarycookiesInt32BE(data, 8 + index * 4)
            sizes.append(size)
            sizeSum += size
        }
        #expect(sizes.allSatisfy { $0 > 0 })
        #expect(headerSize + sizeSum == data.count)
        #expect(sizes[0] != headerSize)
        #expect(binarycookiesInt32BE(data, headerSize) == 0x0000_0100)
        #expect(binarycookiesInt32BE(data, sizes[0]) != 0x0000_0100)

        let parsed = SafariBinaryCookies.parse(data)
        #expect(parsed.map(\.name) == ["sso", "sso-rw", "cf_clearance", "grok_device_id", "gb_anon_id"])
        #expect(parsed.map(\.domain) == [".grok.com", ".grok.com", ".grok.com", ".grok.com", "accounts.x.ai"])
        let live = parsed.filter {
            GrokAppSession.isAllowedHost($0.domain) && GrokAppSession.isLive($0, now: now)
        }
        #expect(live.map(\.name) == parsed.map(\.name))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotspot-cook-sizes-\(UUID().uuidString)", isDirectory: true)
        let cookieDir = root
            .appendingPathComponent("Library/Containers/com.apple.Safari.WebApp/Data/Library/Containers", isDirectory: true)
            .appendingPathComponent("com.apple.Safari.WebApp.215AFFD4-31BD-4F39-96F2-F135904AFFDD", isDirectory: true)
            .appendingPathComponent("Library/WebKit/WebsiteData/Cookies", isDirectory: true)
        try FileManager.default.createDirectory(at: cookieDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try data.write(to: cookieDir.appendingPathComponent("Cookies.binarycookies"))
        #expect(GrokAppSession.hasSignedInCookies(userHome: root, now: now))
        #expect(
            GrokAppSession.cookies(userHome: root, now: now).map(\.name)
                == ["sso", "sso-rw", "cf_clearance", "grok_device_id", "gb_anon_id"]
        )
    }

    @Test
    func grokAppSessionFindsSafariWebAppCookieFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotspot-grok-app-\(UUID().uuidString)", isDirectory: true)
        let webApp = root
            .appendingPathComponent("Library/Containers/com.apple.Safari.WebApp/Data/Library/Containers", isDirectory: true)
            .appendingPathComponent("com.apple.Safari.WebApp.215AFFD4-31BD-4F39-96F2-F135904AFFDD", isDirectory: true)
        let cookieDir = webApp.appendingPathComponent("Library/WebKit/WebsiteData/Cookies", isDirectory: true)
        try FileManager.default.createDirectory(at: cookieDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let cookie = SafariCookie(
            domain: "grok.com",
            name: "sso",
            path: "/",
            value: "session-token",
            expiry: now.addingTimeInterval(3_600)
        )
        try SafariBinaryCookies.encode([cookie]).write(
            to: cookieDir.appendingPathComponent("Cookies.binarycookies")
        )
        #expect(GrokAppSession.hasSignedInCookies(userHome: root, now: now))
        #expect(GrokAppSession.cookies(userHome: root, now: now).map(\.name) == ["sso"])
        #expect(!GrokAppSession.hasSignedInCookies(userHome: root, now: now.addingTimeInterval(10_000)))
    }

    @Test
    func grokCreditsProtobufFeedsSuperGrok() throws {
        let start = UInt64(1_788_134_400)
        let end = UInt64(1_788_739_200)
        let timestampStart = protoVarint(1, start)
        let timestampEnd = protoVarint(1, end)
        let period = protoBytes(2, timestampStart) + protoBytes(3, timestampEnd)
        let prepaid = protoVarint(1, 1250)
        let config = protoFixed32(1, Float(52)) + protoBytes(8, period) + protoBytes(12, prepaid)
        let payload = protoBytes(1, config)
        var frame = Data([0x00])
        let length = UInt32(payload.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(payload)

        let json = try #require(QuotaParsing.billingJSON(fromCreditsProtobuf: frame))
        let now = Date(timeIntervalSince1970: TimeInterval(start + 86_400))
        let superGrok = try #require(QuotaParsing.superGrokBar(from: json, now: now))
        #expect(superGrok.usedText == "52% used")
        #expect(superGrok.state == .ready)
    }

    @Test
    func grokCLIAuthIgnoresLockFileWithoutAuthJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotspot-grok-auth-\(UUID().uuidString)", isDirectory: true)
        let grok = root.appendingPathComponent(".grok", isDirectory: true)
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: grok.appendingPathComponent("auth.json.lock"))
        #expect(GrokCLIAuth.hasSessionLogin(environment: [:], userHome: root) == false)

        let auth = """
        { "https://accounts.x.ai/sign-in": { "key": "tok", "refresh_token": "ref" } }
        """.data(using: .utf8)!
        try auth.write(to: grok.appendingPathComponent("auth.json"))
        #expect(GrokCLIAuth.hasSessionLogin(environment: [:], userHome: root) == true)
    }

    @Test
    func creditKindsStayOffTheSubscriptionCard() {
        #expect(QuotaKind.subscriptionCases == [.cursorModels, .otherModels, .superGrok, .grokBot])
        #expect(QuotaKind.creditCases == [.onDemand, .xaiCredits])
        #expect(QuotaKind.onDemand.title == "On Demand")
        #expect(QuotaKind.xaiCredits.title == "X Credits")
        #expect(QuotaKind.xaiCredits.identitySubtitle == "Plugin")
        #expect(QuotaKind.onDemand.identitySubtitle == nil)
    }

    @Test
    func cursorStateStoreParsesSqliteJSONRows() {
        let json = """
        [{"key":"mcpOAuth.global.[plugin-x-x]","value":"{\\"access_token\\":\\"tok\\"}"}]
        """
        let rows = CursorStateStore.parseJSONRows(json)
        #expect(rows.count == 1)
        #expect(rows[0].key == "mcpOAuth.global.[plugin-x-x]")
        #expect(rows[0].value.contains("access_token"))
    }

    @Test
    func cursorStateStoreReadsItemTableWithoutLoggingValues() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotspot-cursor-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("state.vscdb")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        create.arguments = [
            db.path,
            """
            CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO ItemTable VALUES ('mcpOAuth.global.[plugin-x-x]','{"access_token":"sqlite-x-token","serverUrl":"https://api.x.com/mcp"}');
            INSERT INTO ItemTable VALUES ('cursorAuth/accessToken','cursor-only');
            """,
        ]
        try create.run()
        create.waitUntilExit()
        #expect(create.terminationStatus == 0)

        let token = try #require(CursorStateStore.string(forKey: "cursorAuth/accessToken", database: db))
        #expect(token == "cursor-only")
        #expect(CursorStateStore.readAccessToken(database: db) == .token("cursor-only"))
        let rows = CursorStateStore.rows(
            sql: "SELECT key, value FROM ItemTable WHERE key LIKE 'mcpOAuth.global.%';",
            database: db
        )
        #expect(rows.count == 1)
        #expect(rows[0].key == "mcpOAuth.global.[plugin-x-x]")
        #expect(rows[0].value.contains("sqlite-x-token"))
    }

    @Test
    func timedProcessKillsANeverExitingCommand() {
        let start = Date()
        let result = TimedProcess.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 0.4
        )
        #expect(result.timedOut)
        #expect(result.output == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test
    func cursorStateStoreDoesNotCopyGiantDatabases() {
        #expect(!CursorStateStore.shouldCopyDatabase(byteCount: 5_368_709_120))
        #expect(!CursorStateStore.shouldCopyDatabase(byteCount: 0))
        #expect(CursorStateStore.shouldCopyDatabase(byteCount: 1_048_576))
        let uri = CursorStateStore.sqliteFileURI(
            database: URL(fileURLWithPath: "/tmp/Application Support/state.vscdb"),
            immutable: false
        )
        #expect(uri.hasPrefix("file:"))
        #expect(uri.contains("mode=ro"))
        #expect(uri.contains("Application%20Support"))
        #expect(
            CursorStateStore.sqliteFileURI(
                database: URL(fileURLWithPath: "/tmp/state.vscdb"),
                immutable: true
            ).contains("immutable=1")
        )
    }

    @Test
    func cursorStateStoreQueryTimesOutOnHungSqlite() throws {
        let script = try hungCommandScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let db = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotspot-hung-db-\(UUID().uuidString).vscdb")
        FileManager.default.createFile(atPath: db.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: db) }

        let start = Date()
        let output = CursorStateStore.query(
            sql: "SELECT 1;",
            database: db,
            timeout: 0.4,
            executable: script
        )
        #expect(output == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test
    func cursorStateStoreReadsCopiedDatabaseWhenLiveSqliteTimesOut() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotspot-cursor-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("state.vscdb")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        create.arguments = [
            db.path,
            """
            CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO ItemTable VALUES ('cursorAuth/accessToken','cursor-only');
            """,
        ]
        try create.run()
        create.waitUntilExit()
        #expect(create.terminationStatus == 0)

        let locker = Process()
        locker.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        locker.arguments = [db.path]
        let stdin = Pipe()
        locker.standardInput = stdin
        locker.standardOutput = Pipe()
        locker.standardError = Pipe()
        try locker.run()
        stdin.fileHandleForWriting.write(Data("PRAGMA locking_mode=EXCLUSIVE;\nBEGIN EXCLUSIVE;\n".utf8))
        Thread.sleep(forTimeInterval: 0.15)
        defer {
            locker.terminate()
            try? stdin.fileHandleForWriting.close()
        }

        let start = Date()
        let token = CursorStateStore.string(
            forKey: "cursorAuth/accessToken",
            database: db,
            timeout: 0.5
        )
        #expect(token == "cursor-only")
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test @MainActor
    func quotaMonitorAppliesReadySubscriptionBars() async throws {
        let period = """
        {
          "billingCycleEnd": 1789583069000,
          "planUsage": { "autoPercentUsed": 10.523, "apiPercentUsed": 22.728 }
        }
        """.data(using: .utf8)!
        let sand = """
        { "usagePercent": 40.0, "nextResetTimestampUtc": "2026-08-23T18:24:32.476Z" }
        """.data(using: .utf8)!
        let grok = """
        {
          "config": {
            "creditUsagePercent": 15.0,
            "onDemandCap": { "val": 5000 },
            "onDemandUsed": { "val": 300 },
            "currentPeriod": { "end": "2026-08-23T18:22:26.517846+00:00" }
          }
        }
        """.data(using: .utf8)!

        let suite = "com.hotspotusage.tests.quotaHang.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let sources = QuotaRefreshSources(
            periodUsage: { .success(period) },
            sandUsage: { .payload(sand) },
            grokBilling: { .usage(grok) },
            hasGrokSession: { true }
        )
        let monitor = QuotaMonitor(
            defaults: defaults,
            notifier: QuotaAlertNotifier(defaults: defaults),
            sources: sources,
            fetchTimeout: .seconds(2)
        )
        await monitor.refresh()
        #expect(monitor.bars.first { $0.kind == .superGrok }?.state == .ready)
        #expect(monitor.bars.first { $0.kind == .cursorModels }?.state == .ready)
        #expect(monitor.bars.first { $0.kind == .otherModels }?.state == .ready)
        #expect(monitor.bars.first { $0.kind == .grokBot }?.state == .ready)
        #expect(monitor.lastUpdated != nil)
        #expect(monitor.menuBarKind == .grokBot)
    }

    @Test @MainActor
    func interfaceScaleStartsAtTheDefaultAndStaysInRange() {
        let suite = "com.grokcursorusage.tests.scale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppearancePreferenceStore(defaults: defaults)
        #expect(store.interfaceScale == MenuMetrics.defaultScale)
        #expect(MenuMetrics.percent(for: store.interfaceScale) == 100)
        #expect(MenuMetrics.percent(for: MenuMetrics.minimumScale) == 75)
        #expect(MenuMetrics.percent(for: MenuMetrics.maximumScale) == 125)
        store.interfaceScale = 9
        #expect(store.interfaceScale == MenuMetrics.maximumScale)
        store.interfaceScale = 0.2
        #expect(store.interfaceScale == MenuMetrics.minimumScale)
        let restored = AppearancePreferenceStore(defaults: defaults)
        #expect(restored.interfaceScale == MenuMetrics.minimumScale)
    }

    @Test
    func menuBarFollowsThePoolThatJustMoved() {
        func bar(_ kind: QuotaKind, _ percent: Double) -> QuotaBar {
            QuotaParsing.percentBar(kind: kind, usedPercent: percent, subtitle: "", detail: "")
        }

        let first = QuotaMenuBarFocus.empty.advanced(by: [
            bar(.cursorModels, 15),
            bar(.otherModels, 48),
            bar(.grokBot, 14),
        ])
        #expect(first.kind == .otherModels)

        let grokMoved = first.advanced(by: [
            bar(.cursorModels, 15),
            bar(.otherModels, 48),
            bar(.superGrok, 6),
            bar(.grokBot, 14),
        ])
        #expect(grokMoved.kind == .otherModels)

        let grokRose = grokMoved.advanced(by: [
            bar(.cursorModels, 15),
            bar(.otherModels, 48),
            bar(.superGrok, 8),
            bar(.grokBot, 14),
        ])
        #expect(grokRose.kind == .superGrok)

        let apiRoseMore = grokRose.advanced(by: [
            bar(.cursorModels, 16),
            bar(.otherModels, 55),
            bar(.superGrok, 9),
            bar(.grokBot, 14),
        ])
        #expect(apiRoseMore.kind == .otherModels)

        let held = apiRoseMore.advanced(by: [
            bar(.cursorModels, 16),
            bar(.otherModels, 55),
            bar(.superGrok, 9),
        ])
        #expect(held.kind == .otherModels)

        let apiGone = held.advanced(by: [
            bar(.cursorModels, 16),
            bar(.superGrok, 9),
        ])
        #expect(apiGone.kind == .cursorModels)
    }

    @Test
    func grokBotParsesWeeklySandUsage() throws {
        let json = """
        {
          "usagePercent": 93.1239,
          "nextResetTimestampUtc": "2026-08-23T18:24:32.476Z"
        }
        """.data(using: .utf8)!
        let now = QuotaParsing.parseISODate("2026-08-22T21:28:00Z")!
        let bar = try #require(QuotaParsing.grokBotBar(from: json, now: now))
        #expect(bar.kind == .grokBot)
        #expect(bar.usedText == "93% used")
        #expect(bar.subtitle == "Weekly usage")
        #expect(bar.detail.contains("Resets"))
        #expect(bar.detail.contains("left"))
        #expect(bar.periodEnd == QuotaParsing.parseISODate("2026-08-23T18:24:32.476Z"))
    }

    /// A missing billing fetch keeps the last Grok sample only while that week's
    /// reset is still ahead. After the reset, the old percent must not stay up.
    @Test @MainActor
    func superGrokReusesLastReadyOnlyWhileResetIsAhead() async throws {
        let future = Date().addingTimeInterval(6 * 24 * 60 * 60)
        let past = Date().addingTimeInterval(-2 * 60 * 60)

        let kept = try await refreshedSuperGrok(reset: future)
        #expect(kept.usedText == "11% used")
        #expect(kept.state == .ready)
        let keptReset = try #require(kept.periodEnd)
        #expect(keptReset > Date())

        let dropped = try await refreshedSuperGrok(reset: past)
        #expect(dropped.usedText == "—")
        #expect(dropped.state == .unavailable(QuotaUnavailableCopy.grokWeekReset))
        #expect(dropped.detail == QuotaUnavailableCopy.grokWeekReset)
        #expect(dropped.title == "Grok")
        let droppedReset = try #require(dropped.periodEnd)
        #expect(droppedReset <= Date())
    }

    /// No earlier sample means a missing fetch is still the ordinary sign-in hint,
    /// or no row at all when this Mac has no Grok session.
    @Test @MainActor
    func superGrokMissingFetchWithoutAPriorBarDoesNotClaimTheWeekReset() async throws {
        let signedOut = QuotaRefreshSources(
            periodUsage: { .noToken },
            sandUsage: { .noToken },
            grokBilling: { .unavailable },
            hasGrokSession: { false }
        )
        let (signedOutMonitor, signedOutSuite) = makeMonitor(sources: signedOut)
        defer { UserDefaults(suiteName: signedOutSuite)?.removePersistentDomain(forName: signedOutSuite) }
        await signedOutMonitor.refresh()
        #expect(signedOutMonitor.bars.first { $0.kind == .superGrok } == nil)
        #expect(!signedOutMonitor.bars.contains { $0.detail == QuotaUnavailableCopy.grokWeekReset })

        let signedIn = QuotaRefreshSources(
            periodUsage: { .noToken },
            sandUsage: { .noToken },
            grokBilling: { .unavailable },
            hasGrokSession: { true }
        )
        let (signedInMonitor, signedInSuite) = makeMonitor(sources: signedIn)
        defer { UserDefaults(suiteName: signedInSuite)?.removePersistentDomain(forName: signedInSuite) }
        await signedInMonitor.refresh()
        let bar = try #require(signedInMonitor.bars.first { $0.kind == .superGrok })
        #expect(bar.detail == QuotaUnavailableCopy.grokCLISignInAgain)
        #expect(bar.detail != QuotaUnavailableCopy.grokWeekReset)
    }

    /// A ready Grok sample with no reset date is not reused when billing goes missing.
    @Test @MainActor
    func superGrokWithoutAResetDateIsNotKeptWhenBillingIsMissing() async throws {
        let billing = OneShotGrokBilling(
            first: .usage(Data(#"{"creditUsagePercent":11}"#.utf8)),
            then: .unavailable
        )
        let sources = QuotaRefreshSources(
            periodUsage: { .noToken },
            sandUsage: { .noToken },
            grokBilling: { billing.next() },
            hasGrokSession: { false }
        )
        let (monitor, suite) = makeMonitor(sources: sources)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await monitor.refresh()
        let ready = try #require(monitor.bars.first { $0.kind == .superGrok })
        #expect(ready.usedText == "11% used")
        #expect(ready.periodEnd == nil)
        await monitor.refresh()
        #expect(monitor.bars.first { $0.kind == .superGrok } == nil)
    }

    /// Grok Bot's unreadable payload uses the same reset-date guard.
    @Test @MainActor
    func grokBotReusesLastReadyOnlyWhileResetIsAhead() async throws {
        let future = Date().addingTimeInterval(6 * 24 * 60 * 60)
        let past = Date().addingTimeInterval(-2 * 60 * 60)

        let kept = try await refreshedGrokBot(reset: future)
        #expect(kept.usedText == "11% used")
        #expect(kept.state == .ready)
        let keptReset = try #require(kept.periodEnd)
        #expect(keptReset > Date())

        let dropped = try await refreshedGrokBot(reset: past)
        #expect(dropped.usedText == "—")
        #expect(dropped.detail == QuotaUnavailableCopy.grokBotWeekReset)
        #expect(dropped.state == .unavailable(QuotaUnavailableCopy.grokBotWeekReset))
        #expect(dropped.title == "Grok Bot")
    }

    /// No Grok Bot allowance still removes the row, even if last week was ready.
    @Test @MainActor
    func grokBotNoAllowanceStillHidesTheRowAfterAReadyWeek() async throws {
        let future = Date().addingTimeInterval(6 * 24 * 60 * 60)
        let sand = OneShotSand(
            first: .payload(grokBotSand(percent: 11, reset: future)),
            then: .payload(Data(#"{"enabled":false,"usagePercent":4}"#.utf8))
        )
        let sources = QuotaRefreshSources(
            periodUsage: { .noToken },
            sandUsage: { sand.next() },
            grokBilling: { .unavailable },
            hasGrokSession: { false }
        )
        let (monitor, suite) = makeMonitor(sources: sources)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await monitor.refresh()
        let ready = try #require(monitor.bars.first { $0.kind == .grokBot })
        #expect(ready.usedText == "11% used")
        await monitor.refresh()
        #expect(!monitor.bars.contains { $0.kind == .grokBot })
    }

    /// A real Cursor failure replaces Grok Bot. It does not keep last week's percent.
    @Test @MainActor
    func grokBotFailureReplacesAKeptWeek() async throws {
        let future = Date().addingTimeInterval(6 * 24 * 60 * 60)
        let sand = OneShotSand(
            first: .payload(grokBotSand(percent: 11, reset: future)),
            then: .failed(nil)
        )
        let sources = QuotaRefreshSources(
            periodUsage: { .noToken },
            sandUsage: { sand.next() },
            grokBilling: { .unavailable },
            hasGrokSession: { false }
        )
        let (monitor, suite) = makeMonitor(sources: sources)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await monitor.refresh()
        #expect(monitor.bars.first { $0.kind == .grokBot }?.state == .ready)
        await monitor.refresh()
        let bot = try #require(monitor.bars.first { $0.kind == .grokBot })
        #expect(bot.detail == QuotaUnavailableCopy.grokBotUnreachable)
        #expect(bot.detail != QuotaUnavailableCopy.grokBotWeekReset)
    }

    @Test
    func quotaPaceComparesUsedToElapsedTime() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(10 * 24 * 60 * 60)
        let halfway = start.addingTimeInterval(5 * 24 * 60 * 60)
        #expect(QuotaParsing.pace(usedPercent: 40, start: start, end: end, now: halfway) == .under(10))
        #expect(QuotaParsing.pace(usedPercent: 70, start: start, end: end, now: halfway) == .over(20))
        #expect(QuotaParsing.pace(usedPercent: 50, start: start, end: end, now: halfway) == .onPace)

        let early = start.addingTimeInterval(60 * 60)
        #expect(QuotaParsing.pace(usedPercent: 90, start: start, end: end, now: early) == .onPace)
        #expect(QuotaParsing.pace(usedPercent: 0, start: start, end: end, now: early) == .onPace)
    }

    /// The fetcher keeps any payload `looksLikeBillingJSON` accepts, so the bar
    /// parser must read the same flat shape instead of showing "unavailable".
    @Test
    func superGrokReadsFlatBillingPayloadTheFetcherAccepted() throws {
        let flat = """
        {
          "creditUsagePercent": 41.6,
          "currentPeriod": { "end": "2026-09-13T18:22:26Z" }
        }
        """.data(using: .utf8)!
        #expect(QuotaParsing.looksLikeBillingJSON(flat))
        let now = QuotaParsing.parseISODate("2026-09-06T18:22:26Z")!
        let bar = try #require(QuotaParsing.superGrokBar(from: flat, now: now))
        #expect(bar.usedText == "42% used")
        #expect(bar.detail.contains("Resets Sep 13"))

        let unrelated = Data("{\"hello\":\"world\"}".utf8)
        #expect(!QuotaParsing.looksLikeBillingJSON(unrelated))
        #expect(QuotaParsing.superGrokBar(from: unrelated, now: now) == nil)
    }

    /// Grok 4.7 unified billing can omit `creditUsagePercent` and send only
    /// product rows. Those rows are one weekly pool, so they add up.
    @Test
    func superGrokSumsProductUsageWhenHeadlinePercentIsMissing() throws {
        let json = """
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-09-14T00:00:00Z",
              "end": "2026-09-21T00:00:00Z"
            },
            "productUsage": [
              {"product": "PRODUCT_GROK_BUILD", "usagePercent": 21.2},
              {"product": "Chat", "usagePercent": 18.4}
            ],
            "isUnifiedBillingUser": true
          }
        }
        """.data(using: .utf8)!
        #expect(QuotaParsing.looksLikeBillingJSON(json))
        let now = QuotaParsing.parseISODate("2026-09-18T00:00:00Z")!
        let bar = try #require(QuotaParsing.superGrokBar(from: json, now: now))
        #expect(bar.usedText == "40% used")
        #expect(bar.detail.contains("Resets Sep 20"))

        let headlineWins = """
        {
          "creditUsagePercent": 12,
          "productUsage": [{"product": "Chat", "usagePercent": 80}],
          "currentPeriod": {"end": "2026-09-21T00:00:00Z"}
        }
        """.data(using: .utf8)!
        let kept = try #require(QuotaParsing.superGrokBar(from: headlineWins, now: now))
        #expect(kept.usedText == "12% used")

        let bot = """
        {"creditUsagePercent": 7, "nextResetTimestampUtc": "2026-09-21T00:00:00Z"}
        """.data(using: .utf8)!
        let botBar = try #require(QuotaParsing.grokBotBar(from: bot, now: now))
        #expect(botBar.usedText == "7% used")
    }

    @Test
    func percentBarKeepsRawPercentAboveTheCappedFill() {
        let over = QuotaParsing.percentBar(kind: .superGrok, usedPercent: 130, subtitle: "", detail: "")
        #expect(over.usedFraction == 1)
        #expect(over.usedPercent == 130)
        #expect(over.usedText == "130% used")

        // Overage still burns: 95% at the first sample, 112% later in the day.
        let burned = QuotaBurnEvaluator.evaluate(
            dayKey: "2026-09-05",
            usedFraction: 1.12,
            storedDayKey: "2026-09-05",
            storedStartUsed: 0.95,
            notifiedSteps: 0
        )
        #expect(burned.shouldNotify)
        #expect(burned.notifiedSteps == 1)
    }

    @Test
    func spikeAlertNotifiesOnceOrAtEveryStep() {
        let quiet = QuotaBurnEvaluator.evaluate(
            dayKey: "2026-10-07",
            usedFraction: 0.24,
            storedDayKey: "2026-10-07",
            storedStartUsed: 0.15,
            notifiedSteps: 0,
            mode: .once,
            stepPercent: 15
        )
        #expect(!quiet.shouldNotify)

        let once = QuotaBurnEvaluator.evaluate(
            dayKey: "2026-10-07",
            usedFraction: 0.30,
            storedDayKey: "2026-10-07",
            storedStartUsed: 0.15,
            notifiedSteps: 0,
            mode: .once,
            stepPercent: 15
        )
        #expect(once.shouldNotify)
        #expect(once.notifiedSteps == 1)
        let again = QuotaBurnEvaluator.evaluate(
            dayKey: "2026-10-07",
            usedFraction: 0.50,
            storedDayKey: "2026-10-07",
            storedStartUsed: 0.15,
            notifiedSteps: once.notifiedSteps,
            mode: .once,
            stepPercent: 15
        )
        #expect(!again.shouldNotify)

        let first = QuotaBurnEvaluator.evaluate(
            dayKey: "2026-10-07",
            usedFraction: 0.30,
            storedDayKey: "2026-10-07",
            storedStartUsed: 0.15,
            notifiedSteps: 0,
            mode: .every,
            stepPercent: 15
        )
        #expect(first.shouldNotify)
        #expect(first.notifiedSteps == 1)
        let between = QuotaBurnEvaluator.evaluate(
            dayKey: "2026-10-07",
            usedFraction: 0.40,
            storedDayKey: "2026-10-07",
            storedStartUsed: 0.15,
            notifiedSteps: first.notifiedSteps,
            mode: .every,
            stepPercent: 15
        )
        #expect(!between.shouldNotify)
        let second = QuotaBurnEvaluator.evaluate(
            dayKey: "2026-10-07",
            usedFraction: 0.45,
            storedDayKey: "2026-10-07",
            storedStartUsed: 0.15,
            notifiedSteps: first.notifiedSteps,
            mode: .every,
            stepPercent: 15
        )
        #expect(second.shouldNotify)
        #expect(second.notifiedSteps == 2)

        #expect(QuotaBurnEvaluator.clampPercent(15) == 15)
        #expect(QuotaBurnEvaluator.clampPercent(3) == 5)
        #expect(QuotaBurnEvaluator.clampPercent(100) == 50)
    }

    @Test
    func resetCaptionNeverSaysZeroMinutes() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(QuotaParsing.remainingPhrase(until: reset, now: reset.addingTimeInterval(-30)) == "under a minute")
        #expect(QuotaParsing.remainingPhrase(until: reset, now: reset.addingTimeInterval(-90)) == "1 minute")
        #expect(QuotaParsing.remainingPhrase(until: reset, now: reset) == "")
    }

    @Test
    func resetValueParsesEpochSecondsAndMillisInEitherType() {
        let seconds = 1_789_583_069.0
        let expected = Date(timeIntervalSince1970: seconds)
        #expect(QuotaParsing.parseResetValue(NSNumber(value: seconds)) == expected)
        #expect(QuotaParsing.parseResetValue(NSNumber(value: seconds * 1000)) == expected)
        #expect(QuotaParsing.parseResetValue("1789583069") == expected)
        #expect(QuotaParsing.parseResetValue("1789583069000") == expected)
        #expect(QuotaParsing.parseResetValue("42") == nil)
        #expect(QuotaParsing.parseResetValue(nil) == nil)
    }

    @Test
    func grokCLIRefreshHonorsRootLevelExpiryAndRotatesRefreshTokens() {
        let now = QuotaParsing.parseISODate("2026-09-05T12:00:00Z")!
        let flatExpired: [String: Any] = [
            "access_token": "tok",
            "refresh_token": "ref",
            "oidc_client_id": "cli",
            "expires_at": "2026-09-05T11:59:00Z"
        ]
        #expect(GrokQuotaClient.shouldRefresh(root: flatExpired, now: now))

        let nestedFresh: [String: Any] = [
            "https://accounts.x.ai/sign-in": [
                "key": "tok",
                "refresh_token": "ref",
                "expires_at": "2026-09-05T13:00:00Z"
            ]
        ]
        #expect(!GrokQuotaClient.shouldRefresh(root: nestedFresh, now: now))

        let rotated = GrokQuotaClient.RefreshedToken.parse(
            ["access_token": "new", "refresh_token": "ref2", "expires_in": 1800],
            sentRefreshToken: "ref",
            now: now
        )
        #expect(rotated?.accessToken == "new")
        #expect(rotated?.refreshToken == "ref2")
        #expect(rotated?.expiresAt == now.addingTimeInterval(1800))

        let plain = GrokQuotaClient.RefreshedToken.parse(["access_token": "new"], sentRefreshToken: "ref", now: now)
        #expect(plain?.refreshToken == "ref")
        #expect(plain?.expiresAt == now.addingTimeInterval(GrokQuotaClient.RefreshedToken.defaultLifetime))
        #expect(GrokQuotaClient.RefreshedToken.parse(["error": "invalid_grant"], sentRefreshToken: "ref") == nil)
    }

    @Test
    func snapshotKeepsAReadyBarWhenTheNextSampleIsStillLoading() {
        let ready = SnapshotQuotaBar(
            kind: .cursorModels,
            usedFraction: 0.1,
            usedText: "10% used",
            label: "Cursor Ultra",
            subtitle: "Auto",
            detail: "Resets"
        )
        let previous = QuotaSnapshot(
            version: 1,
            lastUpdated: Date(timeIntervalSince1970: 1_000),
            bars: [ready]
        )
        let loading = SnapshotQuotaBar(
            kind: .cursorModels,
            usedFraction: 0,
            usedText: "—",
            label: "Cursor Models",
            subtitle: "",
            detail: QuotaBar.loadingMessage,
            unavailableMessage: QuotaBar.loadingMessage
        )
        let next = QuotaSnapshot(
            version: 1,
            lastUpdated: Date(timeIntervalSince1970: 2_000),
            bars: [loading]
        )
        let prepared = QuotaSnapshotPublishPolicy.prepared(previous: previous, next: next)
        #expect(prepared.bars.first?.usedText == "10% used")
        #expect(prepared.bars.first?.label == "Cursor Ultra")
        var quiet = prepared
        quiet.lastUpdated = previous.lastUpdated.addingTimeInterval(30)
        #expect(!QuotaSnapshotPublishPolicy.shouldWrite(previous: previous, next: quiet))
    }

    @Test
    func cursorTokenMissingOrExpiredAsksForSignIn() {
        #expect(CursorAccessToken.state(of: nil) == .missing)
        #expect(CursorAccessToken.state(of: "   ") == .missing)
        #expect(CursorAccessToken.state(of: "opaque-token") == .present)

        let expired = cursorJWT(exp: 1_700_000_000)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(CursorAccessToken.state(of: expired, now: now) == .expired)
        let live = cursorJWT(exp: 1_800_000_000)
        #expect(CursorAccessToken.state(of: live, now: now) == .present)

        let rejected = Data(#"{"error":"unauthenticated"}"#.utf8)
        #expect(CursorAccessToken.payloadRejectsSignIn(rejected))
        #expect(
            SandUsageFetch.from(.success(rejected))
                == .expired(CursorServerRejection(statusCode: 200, serverMessage: "unauthenticated"))
        )
        #expect(SandUsageFetch.from(.noToken) == .noToken)
        #expect(SandUsageFetch.from(.expired(nil)) == .expired(nil))
        #expect(SandUsageFetch.from(.failed(nil)) == .failed(nil))
        #expect(SandUsageFetch.from(.timedOut) == .timedOut)
        #expect(SandUsageFetch.from(.keychainDenied) == .keychainDenied)
        #expect(SandUsageFetch.from(.keychainMissing) == .keychainMissing)
        #expect(SandUsageFetch.from(.keychainLocked) == .keychainLocked)

        let allowance = Data(#"{"usagePercent":12}"#.utf8)
        #expect(!CursorAccessToken.payloadRejectsSignIn(allowance))
        #expect(SandUsageFetch.from(.success(allowance)) == .payload(allowance))
    }

    @Test @MainActor
    func grokBotRowExplainsAMissingCursorSignInAndHidesARealMiss() async {
        let signedOut = QuotaRefreshSources(
            periodUsage: { .noToken },
            sandUsage: { .noToken },
            grokBilling: { .unavailable },
            hasGrokSession: { false }
        )
        let (signedOutMonitor, signedOutSuite) = makeMonitor(sources: signedOut)
        defer { UserDefaults(suiteName: signedOutSuite)?.removePersistentDomain(forName: signedOutSuite) }
        await signedOutMonitor.refresh()
        let bot = signedOutMonitor.bars.first { $0.kind == .grokBot }
        #expect(bot?.detail == "Open Cursor once so this Mac can read usage")
        #expect(bot?.detail == QuotaUnavailableCopy.grokBotNoToken)
        #expect(bot?.state == .unavailable(QuotaUnavailableCopy.grokBotNoToken))
        let cursor = signedOutMonitor.bars.first { $0.kind == .cursorModels }
        #expect(cursor?.detail == "Open Cursor once so this Mac can read usage")
        #expect(cursor?.title == "Cursor Auto")
        let api = signedOutMonitor.bars.first { $0.kind == .otherModels }
        #expect(api?.detail == QuotaUnavailableCopy.cursorNoToken)
        #expect(api?.title == "Cursor API")

        let failed = QuotaRefreshSources(
            periodUsage: { .failed(nil) },
            sandUsage: { .failed(nil) },
            grokBilling: { .unavailable },
            hasGrokSession: { false }
        )
        let (failedMonitor, failedSuite) = makeMonitor(sources: failed)
        defer { UserDefaults(suiteName: failedSuite)?.removePersistentDomain(forName: failedSuite) }
        await failedMonitor.refresh()
        #expect(
            failedMonitor.bars.first { $0.kind == .grokBot }?.detail
                == QuotaUnavailableCopy.grokBotUnreachable
        )
        #expect(
            failedMonitor.bars.first { $0.kind == .cursorModels }?.detail
                == QuotaUnavailableCopy.cursorUnreachable
        )
        #expect(
            failedMonitor.bars.first { $0.kind == .cursorModels }?.detail
                != "Open Cursor once so this Mac can read usage"
        )

        let period = """
        { "planUsage": { "autoPercentUsed": 8, "apiPercentUsed": 9 } }
        """.data(using: .utf8)!
        let noAllowance = Data(#"{"enabled":false,"usagePercent":4}"#.utf8)
        let signedIn = QuotaRefreshSources(
            periodUsage: { .success(period) },
            sandUsage: { .payload(noAllowance) },
            grokBilling: { .unavailable },
            hasGrokSession: { false }
        )
        let (signedInMonitor, signedInSuite) = makeMonitor(sources: signedIn)
        defer { UserDefaults(suiteName: signedInSuite)?.removePersistentDomain(forName: signedInSuite) }
        await signedInMonitor.refresh()
        #expect(signedInMonitor.bars.contains { $0.kind == .cursorModels })
        #expect(!signedInMonitor.bars.contains { $0.kind == .grokBot })
    }

    @Test
    func expiredOpaqueCursorTokenAsksToRefresh() async throws {
        let db = try makeCursorStateDatabase([
            (CursorStateStore.accessTokenKey, "cursor-opaque-test"),
            ("cursorAuth/refreshToken", "refresh-should-not-be-read"),
        ])
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        #expect(CursorAccessToken.jwtExpiry("cursor-opaque-test") == nil)
        #expect(CursorAccessToken.state(of: "cursor-opaque-test") == .present)

        let reads = CallLog()
        let sent = CallLog()
        let rejected = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { url in
                reads.add("read")
                return CursorStateStore.readAccessToken(database: url)
            },
            perform: { token in
                sent.add(token)
                return CursorHTTPResponse(statusCode: 401, body: Data())
            }
        )
        #expect(rejected == .expired(CursorServerRejection(statusCode: 401, serverMessage: "")))
        #expect(sent.entries == ["cursor-opaque-test"])
        #expect(reads.entries.count == 2)

        let forbiddenReads = CallLog()
        let forbiddenSent = CallLog()
        let forbidden = await CursorQuotaClient.fetchDashboard(
            method: "GetSandUsageStatus",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { _ in
                forbiddenReads.add("read")
                return .token("cursor-opaque-test")
            },
            perform: { token in
                forbiddenSent.add(token)
                return CursorHTTPResponse(statusCode: 403, body: Data())
            }
        )
        #expect(forbidden == .expired(CursorServerRejection(statusCode: 403, serverMessage: "")))
        #expect(forbiddenSent.entries == ["cursor-opaque-test"])
        #expect(forbiddenReads.entries.count == 2)

        let jwtHTTP = CallLog()
        let jwt = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            now: Date(timeIntervalSince1970: 1_750_000_000),
            readToken: { _ in .token(cursorJWT(exp: 1_700_000_000)) },
            perform: { _ in
                jwtHTTP.add("http")
                return CursorHTTPResponse(statusCode: 200, body: Data())
            }
        )
        #expect(jwt == .expired(nil))
        #expect(jwtHTTP.entries.isEmpty)

        let bodyReads = CallLog()
        let authBody = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { _ in
                bodyReads.add("read")
                return .token("cursor-opaque-test")
            },
            perform: { _ in
                CursorHTTPResponse(
                    statusCode: 200,
                    body: Data(#"{"error":"unauthenticated"}"#.utf8)
                )
            }
        )
        #expect(authBody == .expired(CursorServerRejection(statusCode: 200, serverMessage: "unauthenticated")))
        #expect(bodyReads.entries.count == 1)

        let sequence = TokenSequence(["cursor-old", "cursor-new"])
        let replacedSent = CallLog()
        let usage = Data(#"{"planUsage":{"autoPercentUsed":1}}"#.utf8)
        let replaced = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { _ in sequence.next() },
            perform: { token in
                replacedSent.add(token)
                if token == "cursor-old" {
                    return CursorHTTPResponse(statusCode: 401, body: Data())
                }
                return CursorHTTPResponse(statusCode: 200, body: usage)
            }
        )
        #expect(replaced == .success(usage))
        #expect(replacedSent.entries == ["cursor-old", "cursor-new"])

        let reread = CallLog()
        let rereadTimedOut = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { _ in
                reread.add("read")
                return reread.entries.count == 1 ? .token("cursor-opaque-test") : .timedOut
            },
            perform: { _ in CursorHTTPResponse(statusCode: 401, body: Data()) }
        )
        #expect(rereadTimedOut == .expired(CursorServerRejection(statusCode: 401, serverMessage: "")))
        #expect(reread.entries.count == 2)
    }

    @Test
    func missingCursorTokenIsNotAnExpiredSignIn() async throws {
        let db = try makeCursorStateDatabase([])
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        #expect(CursorStateStore.readAccessToken(database: db) == .missing)
        let missing = URL(fileURLWithPath: "/tmp/hotspot-missing-\(UUID().uuidString).vscdb")
        #expect(CursorStateStore.readAccessToken(database: missing) == .missing)

        let http = CallLog()
        let result = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { url in CursorStateStore.readAccessToken(database: url) },
            perform: { _ in
                http.add("http")
                return CursorHTTPResponse(statusCode: 200, body: Data())
            }
        )
        #expect(result == .noToken)
        #expect(http.entries.isEmpty)

        let network = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { _ in .token("cursor-opaque-test") },
            perform: { _ in nil }
        )
        #expect(network == .failed(nil))

        let server = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { _ in .token("cursor-opaque-test") },
            perform: { _ in CursorHTTPResponse(statusCode: 500, body: Data()) }
        )
        #expect(server == .failed(CursorServerRejection(statusCode: 500, serverMessage: "")))
    }

    @Test
    func cursorStateReadTimeoutIsNotAMissingToken() async throws {
        let script = try hungCommandScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let db = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotspot-token-timeout-\(UUID().uuidString).vscdb")
        #expect(FileManager.default.createFile(atPath: db.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: db) }

        let started = Date()
        let read = CursorStateStore.readAccessToken(database: db, timeout: 0.25, executable: script)
        #expect(read == .timedOut)
        #expect(read != .missing)
        #expect(Date().timeIntervalSince(started) < 4)

        let http = CallLog()
        let first = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { url in
                CursorStateStore.readAccessToken(database: url, timeout: 0.25, executable: script)
            },
            perform: { _ in
                http.add("http")
                return CursorHTTPResponse(statusCode: 200, body: Data())
            }
        )
        #expect(first == .timedOut)
        #expect(first != .noToken)
        #expect(http.entries.isEmpty)

        let cache = CursorAccessTokenCache()
        let reads = CallLog()
        let again = await CursorQuotaClient.fetchDashboard(
            method: "GetSandUsageStatus",
            cache: cache,
            database: db,
            readToken: { _ in
                reads.add("read")
                return .timedOut
            },
            perform: { _ in
                http.add("http")
                return CursorHTTPResponse(statusCode: 200, body: Data())
            }
        )
        let retried = await CursorQuotaClient.fetchDashboard(
            method: "GetSandUsageStatus",
            cache: cache,
            database: db,
            readToken: { _ in
                reads.add("read")
                return .timedOut
            },
            perform: { _ in
                http.add("http")
                return CursorHTTPResponse(statusCode: 200, body: Data())
            }
        )
        #expect(again == .timedOut)
        #expect(retried == .timedOut)
        #expect(reads.entries.count == 2)
        #expect(http.entries.isEmpty)
    }

    @Test
    func cursorTokenIsRereadOnlyAfterRejectionOrADatabaseChange() async throws {
        let db = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotspot-token-cache-\(UUID().uuidString).vscdb")
        #expect(FileManager.default.createFile(atPath: db.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: db) }
        let cache = CursorAccessTokenCache()
        let reads = CallLog()
        let http = CallLog()
        let status = HTTPStatusBox(200)
        let body = Data(#"{"planUsage":{"autoPercentUsed":1}}"#.utf8)
        let responseBody = HTTPBodyBox(body)
        #expect(CursorDashboardAuth.serverMessage(from: body, token: "cursor-opaque-test") == "")
        #expect(
            CursorDashboardAuth.serverMessage(
                from: Data(#"{"usagePercent":4,"enabled":true}"#.utf8),
                token: "cursor-opaque-test"
            ) == ""
        )

        func fetch() async -> CursorDashboardResult {
            await CursorQuotaClient.fetchDashboard(
                method: "GetCurrentPeriodUsage",
                cache: cache,
                database: db,
                readToken: { _ in
                    reads.add("read")
                    return .token("cursor-opaque-test")
                },
                perform: { token in
                    http.add(token)
                    return CursorHTTPResponse(statusCode: status.code, body: responseBody.data)
                }
            )
        }

        #expect(await fetch() == .success(body))
        #expect(await fetch() == .success(body))
        #expect(reads.entries.count == 1)

        let before = CursorStateStore.modificationDate(of: db)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(180)],
            ofItemAtPath: db.path
        )
        let after = CursorStateStore.modificationDate(of: db)
        #expect(before != after)
        #expect(await fetch() == .success(body))
        #expect(reads.entries.count == 2)

        status.code = 401
        responseBody.data = Data()
        let rejection = CursorServerRejection(statusCode: 401, serverMessage: "")
        #expect(await fetch() == .expired(rejection))
        #expect(reads.entries.count == 3)
        #expect(await fetch() == .expired(rejection))
        #expect(reads.entries.count == 3)
        #expect(http.entries.allSatisfy { $0 == "cursor-opaque-test" })
        #expect(http.entries.count == 5)
    }

    @Test
    func cursorAccessTokenCacheCoalescesOneDatabaseRead() async {
        let cache = CursorAccessTokenCache()
        let reads = CallLog()
        let mtime = Date(timeIntervalSince1970: 50)
        async let first: CursorTokenRead = cache.read(mtime: mtime, force: false) {
            reads.add("read")
            try? await Task.sleep(for: .milliseconds(80))
            return .token("cursor-opaque-test")
        }
        async let second: CursorTokenRead = cache.read(mtime: mtime, force: false) {
            reads.add("read")
            try? await Task.sleep(for: .milliseconds(80))
            return .token("cursor-other")
        }
        let left = await first
        let right = await second
        #expect(left == right)
        #expect(reads.entries.count == 1)
    }

    @Test @MainActor
    func expiredSignInMissingTokenAndStateTimeoutUseDifferentCopy() async {
        await expectCursorFailureCopy(
            period: .expired(nil),
            sand: .expired(nil),
            message: "Cursor sign-in expired — open Cursor to refresh"
        )
        let rejection = CursorServerRejection(statusCode: 401, serverMessage: "ERROR_NOT_LOGGED_IN")
        await expectCursorFailureCopy(
            period: .expired(rejection),
            sand: .expired(rejection),
            message: "Cursor sign-in expired — open Cursor to refresh (HTTP 401: ERROR_NOT_LOGGED_IN)"
        )
        await expectCursorFailureCopy(
            period: .noToken,
            sand: .noToken,
            message: "Open Cursor once so this Mac can read usage"
        )
        await expectCursorFailureCopy(
            period: .timedOut,
            sand: .timedOut,
            message: "Couldn't read Cursor state. Quit Cursor if it is open, then Refresh."
        )

        let empty = QuotaRefreshSources(
            periodUsage: { .success(Data("{}".utf8)) },
            sandUsage: { .payload(Data(#"{"enabled":false}"#.utf8)) },
            grokBilling: { .unavailable },
            hasGrokSession: { false }
        )
        let (monitor, suite) = makeMonitor(sources: empty)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await monitor.refresh()
        #expect(
            monitor.bars.first { $0.kind == .cursorModels }?.detail
                == QuotaUnavailableCopy.cursorPoolMissing
        )
        #expect(monitor.bars.first { $0.kind == .cursorModels }?.title == "Cursor")
        #expect(!monitor.bars.contains { $0.kind == .otherModels })
        #expect(!monitor.bars.contains { $0.kind == .grokBot })
    }

    @Test @MainActor
    func aRefreshThatTimesOutIsNotAMissingCursorToken() async {
        let sources = QuotaRefreshSources(
            periodUsage: {
                try? await Task.sleep(for: .seconds(5))
                return .noToken
            },
            sandUsage: {
                try? await Task.sleep(for: .seconds(5))
                return .noToken
            },
            grokBilling: { .unavailable },
            hasGrokSession: { false }
        )
        let suite = "com.grokcursorusage.tests.deadline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = QuotaMonitor(
            defaults: defaults,
            notifier: QuotaAlertNotifier(defaults: defaults),
            sources: sources,
            fetchTimeout: .milliseconds(200)
        )
        await monitor.refresh()
        #expect(
            monitor.bars.first { $0.kind == .cursorModels }?.detail
                == QuotaUnavailableCopy.cursorUnreachable
        )
        #expect(
            monitor.bars.first { $0.kind == .otherModels }?.detail
                == QuotaUnavailableCopy.cursorUnreachable
        )
        #expect(
            monitor.bars.first { $0.kind == .grokBot }?.detail
                == QuotaUnavailableCopy.grokBotUnreachable
        )
        #expect(!monitor.bars.contains { $0.detail == QuotaUnavailableCopy.cursorNoToken })
    }

    @Test
    func spikeAlertRebaselinesWhenThePoolResetsMidDay() {
        let day = "2026-10-07"
        let morning = QuotaBurnEvaluator.evaluate(
            dayKey: day,
            usedFraction: 0.80,
            storedDayKey: nil,
            storedStartUsed: nil,
            notifiedSteps: 0
        )
        #expect(!morning.shouldNotify)
        #expect(morning.startUsed == 0.80)
        #expect(morning.notifiedSteps == 0)

        let noise = QuotaBurnEvaluator.evaluate(
            dayKey: day,
            usedFraction: 0.78,
            storedDayKey: day,
            storedStartUsed: morning.startUsed,
            notifiedSteps: 1,
            mode: .every
        )
        #expect(!noise.shouldNotify)
        #expect(noise.startUsed == 0.80)
        #expect(noise.notifiedSteps == 1)

        let reset = QuotaBurnEvaluator.evaluate(
            dayKey: day,
            usedFraction: 0.10,
            storedDayKey: day,
            storedStartUsed: morning.startUsed,
            notifiedSteps: 1,
            mode: .once
        )
        #expect(!reset.shouldNotify)
        #expect(reset.startUsed == 0.10)
        #expect(reset.notifiedSteps == 0)

        let exactDrop = QuotaBurnEvaluator.evaluate(
            dayKey: day,
            usedFraction: 0.35,
            storedDayKey: day,
            storedStartUsed: 0.40,
            notifiedSteps: 2,
            mode: .every
        )
        #expect(exactDrop.startUsed == 0.35)
        #expect(exactDrop.notifiedSteps == 0)

        let after = QuotaBurnEvaluator.evaluate(
            dayKey: day,
            usedFraction: 0.25,
            storedDayKey: day,
            storedStartUsed: reset.startUsed,
            notifiedSteps: reset.notifiedSteps,
            mode: .once,
            stepPercent: 15
        )
        #expect(after.shouldNotify)
        #expect(after.notifiedSteps == 1)

        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        let nextEnd = Date(timeIntervalSince1970: 3_000)
        let periodReset = QuotaBurnEvaluator.evaluate(
            dayKey: day,
            usedFraction: 0.40,
            storedDayKey: day,
            storedStartUsed: 0.40,
            notifiedSteps: 2,
            mode: .every,
            periodStart: start,
            periodEnd: nextEnd,
            storedPeriodStart: start,
            storedPeriodEnd: end
        )
        #expect(!periodReset.shouldNotify)
        #expect(periodReset.startUsed == 0.40)
        #expect(periodReset.notifiedSteps == 0)

        let samePeriod = QuotaBurnEvaluator.evaluate(
            dayKey: day,
            usedFraction: 0.42,
            storedDayKey: day,
            storedStartUsed: 0.40,
            notifiedSteps: 0,
            periodStart: start,
            periodEnd: end.addingTimeInterval(0.4),
            storedPeriodStart: start,
            storedPeriodEnd: end
        )
        #expect(!samePeriod.shouldNotify)
        #expect(samePeriod.startUsed == 0.40)
        #expect(samePeriod.notifiedSteps == 0)
    }

    @Test @MainActor
    func spikeAlertPersistsAMidDayResetOnThePoolKeys() async {
        let poster = RecordingPoster()
        let suite = "com.grokcursorusage.tests.spikeReset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let box = BillingBox()
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        box.grok = grokBillingJSON(percent: 80, end: end)
        let sources = QuotaRefreshSources(
            periodUsage: { .noToken },
            sandUsage: { .noToken },
            grokBilling: { box.grokFetch },
            hasGrokSession: { true }
        )
        let notifier = QuotaAlertNotifier(defaults: defaults, poster: poster)
        let monitor = QuotaMonitor(defaults: defaults, notifier: notifier, sources: sources, fetchTimeout: .seconds(2))

        await monitor.refresh()
        let prefix = "com.grokcursorusage.quota.superGrok"
        #expect(abs(defaults.double(forKey: "\(prefix).startUsed") - 0.80) < 0.001)
        #expect(defaults.integer(forKey: "\(prefix).steps") == 0)
        #expect(defaults.object(forKey: "\(prefix).periodEnd") != nil)
        #expect(poster.count == 0)

        box.grok = grokBillingJSON(percent: 10, end: end.addingTimeInterval(7 * 24 * 60 * 60))
        await monitor.refresh()
        #expect(abs(defaults.double(forKey: "\(prefix).startUsed") - 0.10) < 0.001)
        #expect(defaults.integer(forKey: "\(prefix).steps") == 0)
        #expect(poster.count == 0)

        box.grok = grokBillingJSON(percent: 25, end: end.addingTimeInterval(7 * 24 * 60 * 60))
        await monitor.refresh()
        #expect(defaults.integer(forKey: "\(prefix).steps") == 1)
        #expect(poster.count == 1)
    }

    @Test
    func grokCLIVersionFallsBackThenRetriesANewerValueOnce() async {
        #expect(GrokCLIVersion.headerValue(detected: nil) == GrokQuotaClient.cliClientVersion)
        #expect(GrokCLIVersion.headerValue(detected: "grok 1.8.0") == "1.8.0")
        #expect(GrokCLIVersion.headerValue(detected: "nope") == GrokQuotaClient.cliClientVersion)
        #expect(GrokCLIVersion.parse("grok version 1.2.3\n") == "1.2.3")
        #expect(GrokCLIVersion.isNewer("1.0.41", than: "1.0.40"))
        #expect(!GrokCLIVersion.isNewer("1.0.9", than: "1.0.40"))

        let package = Data(#"{"name":"@xai-official/grok","version":"1.4.0"}"#.utf8)
        #expect(GrokCLIVersion.version(inPackageJSON: package) == "1.4.0")
        let versionFile = Data(#"{"version":"1.2.3","stable_version":"1.0.0"}"#.utf8)
        #expect(GrokCLIVersion.version(inVersionJSON: versionFile) == "1.2.3")

        let outdated = Data(
            "Your Grok CLI version (1.0.40) is outdated. Please update to version 1.0.41 or later".utf8
        )
        #expect(GrokCLIVersion.isOutdatedClient(statusCode: 426, body: Data()))
        #expect(GrokCLIVersion.isOutdatedClient(statusCode: 400, body: outdated))
        #expect(GrokCLIVersion.requiredVersion(in: outdated) == "1.0.41")
        #expect(
            GrokCLIVersion.retryVersion(sent: "1.0.40", detected: "1.0.55", serverRequired: "1.0.41")
                == "1.0.55"
        )
        #expect(
            GrokCLIVersion.retryVersion(sent: "1.0.40", detected: "1.0.42", serverRequired: "1.0.50")
                == "1.0.50"
        )
        #expect(GrokCLIVersion.retryVersion(sent: "1.0.50", detected: "1.0.50", serverRequired: nil) == nil)

        let calls = VersionCalls()
        let fetch = await GrokQuotaClient.billingFetch(
            headerVersion: "1.0.40",
            redetect: { "1.0.40" },
            perform: { version in
                calls.add(version)
                if version == "1.0.40" {
                    return GrokBillingHTTPResult(statusCode: 426, body: outdated)
                }
                return GrokBillingHTTPResult(
                    statusCode: 200,
                    body: Data(#"{"creditUsagePercent":3}"#.utf8)
                )
            },
            remember: { calls.remember($0) }
        )
        #expect(calls.sent == ["1.0.40", "1.0.41"])
        #expect(calls.remembered == ["1.0.41"])
        #expect(fetch == .usage(Data(#"{"creditUsagePercent":3}"#.utf8)))

        let stuck = VersionCalls()
        let rejected = await GrokQuotaClient.billingFetch(
            headerVersion: GrokQuotaClient.cliClientVersion,
            redetect: { nil },
            perform: { version in
                stuck.add(version)
                return GrokBillingHTTPResult(
                    statusCode: 426,
                    body: Data("Your Grok CLI version (\(version)) is outdated.".utf8)
                )
            }
        )
        #expect(stuck.sent == [GrokQuotaClient.cliClientVersion])
        #expect(rejected == .outdatedClient)

        let other = await GrokQuotaClient.billingFetch(
            headerVersion: "1.0.40",
            redetect: { "9.0.0" },
            perform: { _ in GrokBillingHTTPResult(statusCode: 401, body: Data("unauthorized".utf8)) }
        )
        #expect(other == .unavailable)
    }

    @Test
    func grokCLIVersionReadsInstallMetadataThenTheCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotspot-grok-version-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent(".grok", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"version":"1.2.3","stable_version":"1.0.0"}"#.write(
            to: home.appendingPathComponent("version.json"),
            atomically: true,
            encoding: .utf8
        )
        let fromFile = GrokCLIVersion.installedVersion(
            environment: [:],
            userHome: root,
            run: { _, _ in "9.9.9" }
        )
        #expect(fromFile == "1.2.3")

        try FileManager.default.removeItem(at: home.appendingPathComponent("version.json"))
        let packageDir = root.appendingPathComponent(
            "lib/node_modules/@xai-official/grok",
            isDirectory: true
        )
        let binDir = packageDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let binary = binDir.appendingPathComponent("grok")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try #"{"name":"@xai-official/grok","version":"1.4.0"}"#.write(
            to: packageDir.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )
        let fromPackage = GrokCLIVersion.installedVersion(
            environment: [:],
            userHome: root,
            executables: [binary],
            run: { _, _ in "9.9.9" }
        )
        #expect(fromPackage == "1.4.0")

        try FileManager.default.removeItem(at: packageDir.appendingPathComponent("package.json"))
        let command = VersionCalls()
        let fromCommand = GrokCLIVersion.installedVersion(
            environment: [:],
            userHome: root,
            executables: [binary],
            run: { url, args in
                command.add(url.path)
                command.remember(args.joined(separator: " "))
                return "grok 2.0.1\n"
            }
        )
        #expect(fromCommand == "2.0.1")
        #expect(command.sent == [binary.path])
        #expect(command.remembered == ["--version"])

        let cache = GrokCLIVersionCache()
        let counter = VersionCalls()
        let first = await cache.resolved {
            counter.add("read")
            return "1.6.0"
        }
        let second = await cache.resolved {
            counter.add("read")
            return "9.9.9"
        }
        #expect(first == "1.6.0")
        #expect(second == "1.6.0")
        #expect(counter.sent == ["read"])
    }

    @Test @MainActor
    func outdatedGrokCLIShowsARowInsteadOfABlankBar() async {
        let sources = QuotaRefreshSources(
            periodUsage: { .noToken },
            sandUsage: { .noToken },
            grokBilling: { .outdatedClient },
            hasGrokSession: { true }
        )
        let (monitor, suite) = makeMonitor(sources: sources)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await monitor.refresh()
        let grok = monitor.bars.first { $0.kind == .superGrok }
        #expect(grok?.detail == QuotaUnavailableCopy.grokCLIOutdated)
        #expect(grok?.title == "Grok")
        #expect(grok?.state == .unavailable(QuotaUnavailableCopy.grokCLIOutdated))
    }

    @Test
    func cursorDashboardRequestCarriesTheDesktopChecksum() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let profile = CursorDashboardAuth.Profile(
            version: "3.27.6",
            machineId: "abc123machine",
            macMachineId: "mac999",
            operatingSystem: "darwin",
            architecture: "arm64",
            timeZone: "America/Chicago"
        )
        let checksum = CursorDashboardAuth.checksum(
            machineId: "abc123machine",
            macMachineId: "mac999",
            at: now
        )
        #expect(checksum == "fn-BnklOabc123machine/mac999")
        #expect(
            CursorDashboardAuth.checksum(machineId: "abc123machine", macMachineId: nil, at: now)
                == "fn-BnklOabc123machine"
        )
        #expect(
            CursorDashboardAuth.checksum(machineId: "abc123machine", macMachineId: "", at: now)
                == "fn-BnklOabc123machine"
        )

        let request = CursorDashboardAuth.urlRequest(
            method: "GetCurrentPeriodUsage",
            token: "cursor-opaque-test",
            profile: CursorDashboardAuth.Profile(
                version: profile.version,
                machineId: profile.machineId,
                macMachineId: profile.macMachineId,
                operatingSystem: profile.operatingSystem,
                architecture: profile.architecture,
                timeZone: profile.timeZone,
                deviceMemory: "17179869184"
            ),
            now: now,
            requestID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            traceParent: "00-0123456789abcdef0123456789abcdef-0123456789abcdef-00",
            clientKey: "ab" + String(repeating: "cd", count: 31)
        )
        #expect(
            request.url?.absoluteString
                == "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
        )
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cursor-opaque-test")
        #expect(request.value(forHTTPHeaderField: "x-cursor-checksum") == checksum)
        #expect(request.value(forHTTPHeaderField: "x-cursor-client-version") == "3.27.6")
        #expect(request.value(forHTTPHeaderField: "x-cursor-client-type") == "ide")
        #expect(request.value(forHTTPHeaderField: "x-cursor-client-layout") == "editor")
        #expect(request.value(forHTTPHeaderField: "x-cursor-client-os") == "darwin")
        #expect(request.value(forHTTPHeaderField: "x-cursor-client-arch") == "arm64")
        #expect(request.value(forHTTPHeaderField: "x-cursor-client-device-type") == "desktop")
        #expect(request.value(forHTTPHeaderField: "x-cursor-client-device-memory") == "17179869184")
        #expect(request.value(forHTTPHeaderField: "x-cursor-streaming") == "true")
        #expect(request.value(forHTTPHeaderField: "x-ghost-mode") == "implicit-false")
        #expect(request.value(forHTTPHeaderField: "x-new-onboarding-completed") == "false")
        #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/proto")
        #expect(request.value(forHTTPHeaderField: "Content-Length") == "0")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "gzip,br")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "connect-es/1.6.1")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == CursorDashboardAuth.connectUserAgent)
        #expect(request.value(forHTTPHeaderField: "x-request-id") == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(request.value(forHTTPHeaderField: "x-amzn-trace-id") == "Root=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(request.value(forHTTPHeaderField: "traceparent") == "00-0123456789abcdef0123456789abcdef-0123456789abcdef-00")
        #expect(request.value(forHTTPHeaderField: "x-client-key") == "ab" + String(repeating: "cd", count: 31))
        #expect(request.value(forHTTPHeaderField: "x-cursor-timezone") == "America/Chicago")
        #expect(request.value(forHTTPHeaderField: "x-session-id") == nil)
        #expect(request.value(forHTTPHeaderField: "x-cursor-client-os-version") == nil)
        #expect(request.httpBody == Data())
        let joined = (request.allHTTPHeaderFields ?? [:]).values.joined(separator: "\n")
        #expect(!joined.contains("refresh-should-not-be-read"))
        #expect(!joined.localizedCaseInsensitiveContains("refreshToken"))
        let wire = String(decoding: CursorDashboardAuth.http1Message(for: request), as: UTF8.self)
        #expect(wire.hasPrefix("POST /aiserver.v1.DashboardService/GetCurrentPeriodUsage HTTP/1.1\r\nHost: api2.cursor.sh\r\n"))
        #expect(wire.contains("Content-Type: application/proto\r\n"))
        #expect(wire.contains("Content-Length: 0\r\n"))
        #expect(wire.contains("User-Agent: connect-es/1.6.1\r\n"))
        #expect(wire.contains("Accept-Encoding: gzip,br\r\n"))
        #expect(wire.contains("Cookie: \r\n") || wire.contains("Cookie:\r\n"))
        #expect(!wire.contains("Cookie-"))
        #expect(!wire.contains("{}"))
        #expect(!wire.contains("x-session-id"))
        #expect(wire.hasSuffix("\r\n\r\n"))

        let sand = CursorDashboardAuth.urlRequest(
            method: "GetSandUsageStatus",
            token: "cursor-opaque-test",
            profile: CursorDashboardAuth.Profile(
                version: "3.27.6",
                machineId: nil,
                macMachineId: "ignored-without-machine",
                operatingSystem: "darwin",
                architecture: "x64",
                timeZone: nil
            ),
            now: now,
            requestID: "request-test"
        )
        #expect(sand.value(forHTTPHeaderField: "x-cursor-checksum") == nil)
        #expect(sand.value(forHTTPHeaderField: "Authorization") == "Bearer cursor-opaque-test")
        #expect(sand.url?.absoluteString.hasSuffix("GetSandUsageStatus") == true)

        let storage = Data(
            #"{"telemetry.machineId":"abc123machine","telemetry.macMachineId":"mac999","cursorAuth/refreshToken":"refresh-should-not-be-read"}"#
                .utf8
        )
        let ids = CursorDashboardAuth.machineIDs(from: storage)
        #expect(ids.machineId == "abc123machine")
        #expect(ids.macMachineId == "mac999")
        #expect(CursorDashboardAuth.installedVersion(from: Data(#"{"version":" 3.27.6 "}"#.utf8)) == "3.27.6")
    }

    @Test
    func cursorDashboardProfileReadsMachineIDsBesideTheStateDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotspot-cursor-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("storage.json")
        let product = directory.appendingPathComponent("product.json")
        try #"{"telemetry.machineId":"m-1","telemetry.macMachineId":"mac-1"}"#
            .write(to: storage, atomically: true, encoding: .utf8)
        try #"{"version":"9.9.9"}"#.write(to: product, atomically: true, encoding: .utf8)

        let profile = CursorDashboardAuth.profile(
            storageFile: storage,
            productFiles: [product],
            operatingSystem: "darwin",
            architecture: "arm64",
            timeZone: "UTC",
            fallbackVersion: "3.27.6",
            deviceMemory: nil,
            resolveLiveIDs: false
        )
        #expect(profile == CursorDashboardAuth.Profile(
            version: "9.9.9",
            machineId: "m-1",
            macMachineId: "mac-1",
            operatingSystem: "darwin",
            architecture: "arm64",
            timeZone: "UTC"
        ))
        let live = CursorDashboardAuth.profile(
            storageFile: storage,
            productFiles: [product],
            operatingSystem: "darwin",
            architecture: "arm64",
            timeZone: "UTC",
            fallbackVersion: "3.27.6",
            deviceMemory: "1024",
            liveMachineID: "live-machine",
            liveMacMachineID: "live-mac",
            resolveLiveIDs: true
        )
        #expect(live.machineId == "live-machine")
        #expect(live.macMachineId == "live-mac")
        #expect(live.deviceMemory == "1024")

        let missing = CursorDashboardAuth.profile(
            storageFile: directory.appendingPathComponent("missing.json"),
            productFiles: [directory.appendingPathComponent("nope.json")],
            operatingSystem: "darwin",
            architecture: "x64",
            timeZone: nil,
            fallbackVersion: "3.27.6",
            deviceMemory: nil,
            resolveLiveIDs: false
        )
        #expect(missing.machineId == nil)
        #expect(missing.macMachineId == nil)
        #expect(missing.version == "3.27.6")
    }

    @Test
    func cursorDashboardProtoRequestMatchesCursor3276() throws {
        let generated = CursorDashboardAuth.urlRequest(
            method: "GetSandUsageStatus",
            token: "cursor-opaque-test",
            profile: CursorDashboardAuth.Profile(
                version: "3.27.6",
                machineId: nil,
                macMachineId: nil,
                operatingSystem: "darwin",
                architecture: "x64",
                timeZone: nil
            )
        )
        let trace = try #require(generated.value(forHTTPHeaderField: "traceparent"))
        #expect(trace.count == 55)
        #expect(trace.hasPrefix("00-"))
        #expect(trace.hasSuffix("-00"))
        let parts = trace.split(separator: "-")
        #expect(parts.count == 4)
        #expect(parts[1].count == 32)
        #expect(parts[2].count == 16)
        #expect(parts[1].allSatisfy { $0.isHexDigit })
        #expect(parts[2].allSatisfy { $0.isHexDigit })
        let key = try #require(generated.value(forHTTPHeaderField: "x-client-key"))
        #expect(key.count == 64)
        #expect(key.allSatisfy { $0.isHexDigit })
        #expect(key == CursorDashboardAuth.processClientKey)
        #expect(generated.value(forHTTPHeaderField: "x-cursor-client-version") == "3.27.6")
        #expect(generated.value(forHTTPHeaderField: "x-session-id") == nil)
        #expect(generated.httpBody == Data())

        let ioreg = """
        +-o Root  <class IOPlatformExpertDevice>
          | "IOPlatformUUID" = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
        """
        let uuid = try #require(CursorDashboardAuth.platformUUID(from: ioreg))
        #expect(uuid == "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        #expect(
            CursorDashboardAuth.sha256Hex(uuid)
                == "a447ee1578a84992cb7a7ce115d8c83d9a3a600d9ecb42c1638321e696418bce"
        )
        #expect(
            CursorDashboardAuth.sha256Hex("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let mac = try #require(
            CursorDashboardAuth.firstEligibleMAC([
                "00:00:00:00:00:00",
                "FF-FF-FF-FF-FF-FF",
                "ac:de:48:00:11:22",
                "AA-BB-CC-DD-EE-FF",
            ])
        )
        #expect(mac == "aa:bb:cc:dd:ee:ff")
        #expect(
            CursorDashboardAuth.sha256Hex(mac)
                == "c1582e87c802221899199e286ead9a7ed13eb3b5e3827be6cc149fb82a9e04f7"
        )
        #expect(
            CursorDashboardAuth.firstEligibleMAC(["02:00:00:00:00:01"]) == "02:00:00:00:00:01"
        )

        let period = data(hex: "0880e2cfaa061080f09dc7061a126100000000000029406900000000000044405a0a4175746f2031322e3525")
        let json = try #require(CursorDashboardAuth.usageJSON(method: "GetCurrentPeriodUsage", body: period))
        let bars = try #require(
            QuotaParsing.cursorBars(from: json, now: Date(timeIntervalSince1970: 1_720_000_000))
        )
        #expect(bars.map(\.usedPercent) == [12.5, 40])

        let hidden = data(hex: "0a060880e2cfaa0612060880f09dc706190000000000001d4020017a09537570657247726f6b")
        let hiddenJSON = try #require(CursorDashboardAuth.usageJSON(method: "GetSandUsageStatus", body: hidden))
        #expect(QuotaParsing.grokBotBar(from: hiddenJSON) == nil)

        let open = data(hex: "190000000000001d40")
        let openJSON = try #require(CursorDashboardAuth.usageJSON(method: "GetSandUsageStatus", body: open))
        let bot = try #require(
            QuotaParsing.grokBotBar(from: openJSON, now: Date(timeIntervalSince1970: 1_720_000_000))
        )
        #expect(bot.usedPercent == 7.25)

        let token = "cursor-opaque-test"
        let leaked = Data(
            #"{"code":"unauthenticated","message":"nope Bearer \#(token) and cursor-abcdefghijklmnopqrstuvwxyz"}"#.utf8
        )
        let message = CursorDashboardAuth.serverMessage(from: leaked, token: token)
        #expect(message.contains("unauthenticated"))
        #expect(!message.contains(token))
        #expect(!message.contains("abcdefghijklmnopqrstuvwxyz"))
        #expect(message.contains("[redacted]"))
        let shown = QuotaUnavailableCopy.explained(
            QuotaUnavailableCopy.cursorSignInExpired,
            CursorServerRejection(statusCode: 401, serverMessage: message)
        )
        #expect(shown.hasPrefix(QuotaUnavailableCopy.cursorSignInExpired + " (HTTP 401:"))
        #expect(!shown.contains(token))
        #expect(
            QuotaUnavailableCopy.explained(QuotaUnavailableCopy.cursorSignInExpired, nil)
                == QuotaUnavailableCopy.cursorSignInExpired
        )

        let body = Data(#"{"code":"unauthenticated","message":"ERROR_NOT_LOGGED_IN"}"#.utf8)
        let raw = Data(
            "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
                .utf8
        ) + body
        let parsed = try #require(CursorDashboardAuth.parseHTTP1(raw))
        #expect(parsed.statusCode == 401)
        #expect(parsed.body == body)
        #expect(CursorDashboardAuth.http1MessageIsComplete(raw))
        let chunked = Data("HTTP/1.1 500 ERR\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n".utf8)
        #expect(CursorDashboardAuth.parseHTTP1(chunked)?.body == Data("hello".utf8))

        let plain = Data(#"{"usagePercent":1}"#.utf8)
        let compressed = try gzipData(plain)
        let inflated = CursorDashboardAuth.decodedBody(
            CursorHTTPResponse(statusCode: 200, body: compressed, contentEncoding: "gzip")
        )
        guard case .success(let decoded) = inflated else {
            Issue.record("gzip decode failed")
            return
        }
        #expect(decoded == plain)
    }

    @Test
    func cursorServerRejectionShowsTheStatusAndHidesTheToken() async throws {
        let token = "cursor-opaque-test"
        let db = try makeCursorStateDatabase([
            (CursorStateStore.accessTokenKey, token),
        ])
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        let body = Data(#"{"code":"unauthenticated","message":"ERROR_NOT_LOGGED_IN \#(token)"}"#.utf8)
        let rejected = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { _ in .token(token) },
            perform: { _ in CursorHTTPResponse(statusCode: 401, body: body) }
        )
        guard case .expired(let rejection) = rejected else {
            Issue.record("expected an expired sign-in")
            return
        }
        #expect(rejection?.statusCode == 401)
        #expect(rejection?.serverMessage.contains("ERROR_NOT_LOGGED_IN") == true)
        #expect(rejection?.serverMessage.contains(token) == false)
        let logged = CursorDashboardAuth.unifiedLogFields(
            CursorServerRejection(
                statusCode: 401,
                serverMessage: "unauthenticated: Error Bearer cursor-abcdefghijklmnopqrstuvwxyz"
            )
        )
        #expect(CursorDashboardLog.subsystem == "com.grokcursorusage.app")
        #expect(CursorDashboardLog.category == "cursor-dashboard")
        #expect(GrokBillingLog.subsystem == CursorDashboardLog.subsystem)
        #expect(GrokBillingLog.category == "grok-billing")
        #expect(GrokBillingLog.isHTMLChallenge(Data("<!DOCTYPE html><html>".utf8)))
        #expect(GrokBillingLog.isHTMLChallenge(Data("<html><body>nope</body></html>".utf8)))
        #expect(!GrokBillingLog.isHTMLChallenge(Data(#"{"creditUsagePercent":1}"#.utf8)))
        #expect(!GrokBillingLog.isHTMLChallenge(Data()))
        #expect(logged.statusCode == 401)
        #expect(logged.message == "unauthenticated: Error Bearer [redacted]")
        #expect(!logged.message.contains("abcdefghijklmnopqrstuvwxyz"))

        let garbage = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { _ in .token(token) },
            perform: { _ in CursorHTTPResponse(statusCode: 200, body: Data([0xff, 0x00])) }
        )
        #expect(
            garbage
                == .failed(
                    CursorServerRejection(
                        statusCode: 200,
                        serverMessage: "Cursor returned a usage body this app could not read."
                    )
                )
        )

        let period = data(hex: "0880e2cfaa061080f09dc7061a126100000000000029406900000000000044405a0a4175746f2031322e3525")
        let success = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { _ in .token(token) },
            perform: { _ in CursorHTTPResponse(statusCode: 200, body: period) }
        )
        guard case .success(let payload) = success else {
            Issue.record("expected proto usage to become JSON")
            return
        }
        let bars = try #require(
            QuotaParsing.cursorBars(from: payload, now: Date(timeIntervalSince1970: 1_720_000_000))
        )
        #expect(bars.map(\.usedPercent) == [12.5, 40])
        #expect(!String(decoding: payload, as: UTF8.self).contains(token))
    }

    @Test
    func safeStorageDecryptsTheFixedChromiumCiphertext() {
        let password = Data("pbkdf2-test-password".utf8)
        let key = Data([
            0x29, 0xd0, 0x84, 0xeb, 0x95, 0x46, 0x19, 0x8b,
            0x55, 0x9b, 0x4a, 0x38, 0xca, 0x28, 0x6a, 0xf3,
        ])
        #expect(CursorSafeStorage.deriveKey(password) == key)

        let plaintext = Data("usage-token-plaintext".utf8)
        let ciphertext = Data([
            0x4d, 0xc9, 0xcc, 0xc7, 0x1b, 0x56, 0x06, 0xc9,
            0x3f, 0x74, 0x7c, 0x44, 0x28, 0x9e, 0x2a, 0x8e,
            0x03, 0x64, 0x00, 0x6f, 0xa1, 0xd3, 0x22, 0x84,
            0x43, 0xd5, 0x1d, 0x23, 0x39, 0x59, 0xbc, 0x47,
        ])
        #expect(CursorSafeStorage.decrypt(ciphertext: ciphertext, password: password) == plaintext)
        var prefixed = Data([0x76, 0x31, 0x30])
        prefixed.append(ciphertext)
        #expect(CursorSafeStorage.decrypt(ciphertext: prefixed, password: password) == plaintext)
        #expect(
            CursorSafeStorage.openEnvelope(
                "cursor-safe-storage:v1:djEwTcnMxxtWBsk/dHxEKJ4qjgNkAG+h0yKEQ9UdIzlZvEc=",
                password: password
            ) == "usage-token-plaintext"
        )

        let jwt = cursorJWT(exp: 1_600_000_000)
        #expect(jwt == "eyJhbGciOiJub25lIn0.eyJleHAiOjE2MDAwMDAwMDB9")
        let jwtCiphertext = Data([
            0xcc, 0x2a, 0x88, 0x54, 0xc6, 0xa8, 0x81, 0x7f,
            0x04, 0xb3, 0xaf, 0xac, 0xd2, 0x04, 0x6b, 0x46,
            0x01, 0xf8, 0x2d, 0xab, 0x89, 0x96, 0x99, 0x3d,
            0xc4, 0x9c, 0x51, 0x72, 0xdb, 0x70, 0x5f, 0x01,
            0x69, 0x13, 0xca, 0x4e, 0x78, 0x96, 0xbf, 0x94,
            0xe8, 0x2a, 0x0f, 0x1e, 0x12, 0x13, 0x5d, 0x56,
        ])
        #expect(CursorSafeStorage.decrypt(ciphertext: jwtCiphertext, password: password) == Data(jwt.utf8))
        #expect(
            CursorSafeStorage.openEnvelope(
                "cursor-safe-storage:v1:djEwzCqIVMaogX8Es6+s0gRrRgH4LauJlpk9xJxRcttwXwFpE8pOeJa/lOgqDx4SE11W",
                password: password
            ) == jwt
        )
        #expect(CursorAccessToken.jwtExpiry(jwt) == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(CursorAccessToken.jwtExpiry("usage-token-plaintext") == nil)
    }

    @Test
    func keychainAccountOrderAndDenialStatuses() {
        #expect(CursorSafeStorage.service == "Cursor Safe Storage")
        #expect(CursorSafeStorage.account == "Cursor Key")
        #expect(CursorSafeStorage.legacyAccount == "Cursor")
        #expect(CursorSafeStorage.prompt == QuotaUnavailableCopy.cursorKeychainDenied)

        let secret = Data("pbkdf2-test-password".utf8)
        #expect(CursorKeychainAccess.result(status: CursorKeychainAccess.success, data: secret) == .password(secret))
        #expect(CursorKeychainAccess.result(status: CursorKeychainAccess.success, data: Data()) == .notFound)
        #expect(CursorKeychainAccess.result(status: CursorKeychainAccess.userCanceled, data: secret) == .denied)
        #expect(CursorKeychainAccess.result(status: CursorKeychainAccess.authFailed, data: nil) == .denied)
        #expect(CursorKeychainAccess.result(status: CursorKeychainAccess.interactionNotAllowed, data: nil) == .denied)
        #expect(CursorKeychainAccess.result(status: CursorKeychainAccess.itemNotFound, data: nil) == .notFound)
        #expect(CursorKeychainAccess.userCanceled == -128)
        #expect(CursorKeychainAccess.authFailed == -25293)
        #expect(CursorKeychainAccess.interactionNotAllowed == -25308)
        #expect(CursorKeychainAccess.itemNotFound == -25300)

        var legacyReads = 0
        let denied = CursorSafeStorage.resolve(primary: .denied) {
            legacyReads += 1
            return .password(secret)
        }
        #expect(denied == .denied)
        #expect(legacyReads == 0)
        let migrated = CursorSafeStorage.resolve(primary: .notFound) {
            legacyReads += 1
            return .password(secret)
        }
        #expect(migrated == .password(secret))
        #expect(legacyReads == 1)
    }

    @Test
    func plaintextTokenDoesNotReadTheKeychain() async throws {
        let db = try emptyStateDatabase()
        defer { try? FileManager.default.removeItem(at: db) }
        let lookups = CallLog()
        let sent = CallLog()
        let result = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { _ in .token("cursor-opaque-test") },
            perform: { token in
                sent.add(token)
                return CursorHTTPResponse(statusCode: 200, body: Data("{}".utf8))
            },
            keychainPassword: {
                lookups.add("keychain")
                return .denied
            },
            secrets: CursorSafeStorageSecrets()
        )
        #expect(result == .success(Data("{}".utf8)))
        #expect(sent.entries == ["cursor-opaque-test"])
        #expect(lookups.entries.isEmpty)
    }

    @Test
    func encryptedAccessTokenIsDecryptedBeforeTheDashboardCall() async throws {
        let db = try emptyStateDatabase()
        defer { try? FileManager.default.removeItem(at: db) }
        let secrets = CursorSafeStorageSecrets()
        let lookups = CallLog()
        let sent = CallLog()
        let envelope = "cursor-safe-storage:v1:djEwTcnMxxtWBsk/dHxEKJ4qjgNkAG+h0yKEQ9UdIzlZvEc="
        let password = Data("pbkdf2-test-password".utf8)

        func fetch(status: Int) async -> CursorDashboardResult {
            await CursorQuotaClient.fetchDashboard(
                method: "GetCurrentPeriodUsage",
                cache: CursorAccessTokenCache(),
                database: db,
                readToken: { _ in .token(envelope) },
                perform: { token in
                    sent.add(token)
                    return CursorHTTPResponse(statusCode: status, body: Data())
                },
                keychainPassword: {
                    lookups.add("keychain")
                    return .password(password)
                },
                secrets: secrets
            )
        }

        let rejection = CursorServerRejection(statusCode: 401, serverMessage: "")
        #expect(await fetch(status: 401) == .expired(rejection))
        #expect(sent.entries == ["usage-token-plaintext"])
        #expect(lookups.entries.count == 1)
        #expect(!sent.entries.joined().contains("cursor-safe-storage"))
    }

    @Test
    func expiredDecryptedJWTIsNotSent() async throws {
        let db = try emptyStateDatabase()
        defer { try? FileManager.default.removeItem(at: db) }
        let sent = CallLog()
        let envelope = "cursor-safe-storage:v1:djEwzCqIVMaogX8Es6+s0gRrRgH4LauJlpk9xJxRcttwXwFpE8pOeJa/lOgqDx4SE11W"
        let result = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            readToken: { _ in .token(envelope) },
            perform: { _ in
                sent.add("sent")
                return CursorHTTPResponse(statusCode: 200, body: Data())
            },
            keychainPassword: { .password(Data("pbkdf2-test-password".utf8)) },
            secrets: CursorSafeStorageSecrets()
        )
        #expect(result == .expired(nil))
        #expect(sent.entries.isEmpty)
    }

    @Test
    func keychainDenialDoesNotPromptAgainUntilRefresh() async throws {
        let db = try emptyStateDatabase()
        defer { try? FileManager.default.removeItem(at: db) }
        let secrets = CursorSafeStorageSecrets()
        let lookups = CallLog()
        let sent = CallLog()
        let envelope = "cursor-safe-storage:v1:djEwTcnMxxtWBsk/dHxEKJ4qjgNkAG+h0yKEQ9UdIzlZvEc="
        let cache = CursorAccessTokenCache()

        func fetch() async -> CursorDashboardResult {
            await CursorQuotaClient.fetchDashboard(
                method: "GetCurrentPeriodUsage",
                cache: cache,
                database: db,
                readToken: { _ in .token(envelope) },
                perform: { _ in
                    sent.add("sent")
                    return nil
                },
                keychainPassword: {
                    lookups.add("keychain")
                    return .denied
                },
                secrets: secrets
            )
        }

        #expect(await fetch() == .keychainDenied)
        #expect(await fetch() == .keychainDenied)
        #expect(lookups.entries.count == 1)
        await secrets.allowPromptAgain()
        #expect(await fetch() == .keychainDenied)
        #expect(lookups.entries.count == 2)
        #expect(sent.entries.isEmpty)
    }

    @Test
    func missingKeychainItemIsRetriedAndIsNotADenial() async throws {
        let db = try emptyStateDatabase()
        defer { try? FileManager.default.removeItem(at: db) }
        let lookups = CallLog()
        let envelope = "cursor-safe-storage:v1:djEwTcnMxxtWBsk/dHxEKJ4qjgNkAG+h0yKEQ9UdIzlZvEc="
        let cache = CursorAccessTokenCache()
        let secrets = CursorSafeStorageSecrets()

        func fetch() async -> CursorDashboardResult {
            await CursorQuotaClient.fetchDashboard(
                method: "GetSandUsageStatus",
                cache: cache,
                database: db,
                readToken: { _ in .token(envelope) },
                perform: { _ in nil },
                keychainPassword: {
                    lookups.add("keychain")
                    return .notFound
                },
                secrets: secrets
            )
        }

        #expect(await fetch() == .keychainMissing)
        #expect(await fetch() == .keychainMissing)
        #expect(lookups.entries.count == 2)
        #expect(SandUsageFetch.from(await fetch()) == .keychainMissing)
        #expect(lookups.entries.count == 3)
    }

    @Test
    func oneAllowIsSharedByConcurrentEnvelopeReads() async {
        let secrets = CursorSafeStorageSecrets()
        let lookups = CallLog()
        let envelope = "cursor-safe-storage:v1:djEwTcnMxxtWBsk/dHxEKJ4qjgNkAG+h0yKEQ9UdIzlZvEc="
        let lookup: @Sendable () async -> CursorKeychainPasswordResult = {
            lookups.add("keychain")
            try? await Task.sleep(for: .milliseconds(40))
            return .password(Data("pbkdf2-test-password".utf8))
        }
        async let first = secrets.unlock(.token(envelope), lookup: lookup)
        async let second = secrets.unlock(.token(envelope), lookup: lookup)
        let left = await first
        let right = await second
        #expect(left == .token("usage-token-plaintext"))
        #expect(right == .token("usage-token-plaintext"))
        #expect(lookups.entries.count == 1)
        let third = await secrets.unlock(.token(envelope), lookup: lookup)
        #expect(third == .token("usage-token-plaintext"))
        #expect(lookups.entries.count == 1)
    }

    @Test
    func undecryptableEnvelopeIsNotSent() async throws {
        let db = try emptyStateDatabase()
        defer { try? FileManager.default.removeItem(at: db) }
        let sent = CallLog()
        let envelope = "cursor-safe-storage:v1:djEwTcnMxxtWBsk/dHxEKJ4qjgNkAG+h0yKEQ9UdIzlZvEc="
        let result = await CursorQuotaClient.fetchDashboard(
            method: "GetCurrentPeriodUsage",
            cache: CursorAccessTokenCache(),
            database: db,
            readToken: { _ in .token(envelope) },
            perform: { _ in
                sent.add("sent")
                return nil
            },
            keychainPassword: { .password(Data("not-the-keychain-password".utf8)) },
            secrets: CursorSafeStorageSecrets()
        )
        #expect(result == .keychainLocked)
        #expect(sent.entries.isEmpty)
    }

    @Test @MainActor
    func keychainDenialAndAMissingItemUseDifferentCopy() async {
        await expectCursorFailureCopy(
            period: .keychainDenied,
            sand: .keychainDenied,
            message: "Allow Keychain access to read Cursor usage"
        )
        await expectCursorFailureCopy(
            period: .keychainMissing,
            sand: .keychainMissing,
            message: "Cursor's Keychain item was not found. Open Cursor, then Refresh."
        )
        await expectCursorFailureCopy(
            period: .keychainLocked,
            sand: .keychainLocked,
            message: "Cursor's saved sign-in could not be unlocked."
        )
    }
}

@MainActor
private func expectCursorFailureCopy(
    period: CursorDashboardResult,
    sand: SandUsageFetch,
    message: String
) async {
    let sources = QuotaRefreshSources(
        periodUsage: { period },
        sandUsage: { sand },
        grokBilling: { .unavailable },
        hasGrokSession: { false }
    )
    let (monitor, suite) = makeMonitor(sources: sources)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    await monitor.refresh()
    for kind in [QuotaKind.cursorModels, QuotaKind.otherModels, QuotaKind.grokBot] {
        let bar = monitor.bars.first { $0.kind == kind }
        #expect(bar?.detail == message)
        #expect(bar?.state == .unavailable(message))
        if kind == .grokBot {
            #expect(bar?.title == "Grok Bot")
        } else {
            #expect(bar?.title == kind.title)
        }
    }
    #expect(!monitor.bars.contains { $0.detail == "Grok Bot usage is unavailable" })
    #expect(!monitor.bars.contains { $0.detail == "Grok Bot weekly usage is unavailable" })
}

@MainActor
private func makeMonitor(sources: QuotaRefreshSources) -> (QuotaMonitor, String) {
    let suite = "com.grokcursorusage.tests.monitor.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let monitor = QuotaMonitor(
        defaults: defaults,
        notifier: QuotaAlertNotifier(defaults: defaults),
        sources: sources,
        fetchTimeout: .seconds(2)
    )
    return (monitor, suite)
}

private func emptyStateDatabase() throws -> URL {
    let db = FileManager.default.temporaryDirectory
        .appendingPathComponent("safestorage-\(UUID().uuidString).vscdb")
    if !FileManager.default.createFile(atPath: db.path, contents: Data()) {
        throw EmptyStateDatabaseFailed()
    }
    return db
}

private struct EmptyStateDatabaseFailed: Error {}

private func data(hex: String) -> Data {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
        index = next
    }
    return Data(bytes)
}

private func gzipData(_ data: Data) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c"]
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    stdin.fileHandleForWriting.write(data)
    try stdin.fileHandleForWriting.close()
    let compressed = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw GzipFailed()
    }
    return compressed
}

private struct GzipFailed: Error {}

/// First refresh paints 11% from `reset`. Later billing fetches are `.unavailable`.
/// The percent stays only while that reset is still ahead.
@MainActor
private func refreshedSuperGrok(reset: Date) async throws -> QuotaBar {
    let billing = OneShotGrokBilling(
        first: grokBillingJSON(percent: 11, end: reset),
        then: .unavailable
    )
    let sources = QuotaRefreshSources(
        periodUsage: { .noToken },
        sandUsage: { .noToken },
        grokBilling: { billing.next() },
        hasGrokSession: { false }
    )
    let (monitor, suite) = makeMonitor(sources: sources)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    await monitor.refresh()
    let ready = try #require(monitor.bars.first { $0.kind == .superGrok })
    #expect(ready.usedText == "11% used")
    #expect(ready.state == .ready)
    await monitor.refresh()
    await monitor.refresh()
    return try #require(monitor.bars.first { $0.kind == .superGrok })
}

/// First refresh paints 11%. Later sand payloads do not parse, so the bar
/// falls through to the reset-date guard.
@MainActor
private func refreshedGrokBot(reset: Date) async throws -> QuotaBar {
    let sand = OneShotSand(
        first: .payload(grokBotSand(percent: 11, reset: reset)),
        then: .payload(Data("{}".utf8))
    )
    let sources = QuotaRefreshSources(
        periodUsage: { .noToken },
        sandUsage: { sand.next() },
        grokBilling: { .unavailable },
        hasGrokSession: { false }
    )
    let (monitor, suite) = makeMonitor(sources: sources)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    await monitor.refresh()
    let ready = try #require(monitor.bars.first { $0.kind == .grokBot })
    #expect(ready.usedText == "11% used")
    #expect(ready.state == .ready)
    await monitor.refresh()
    await monitor.refresh()
    return try #require(monitor.bars.first { $0.kind == .grokBot })
}

private func grokBotSand(percent: Double, reset: Date) -> Data {
    let stamp = ISO8601DateFormatter().string(from: reset)
    let json = """
    { "usagePercent": \(percent), "nextResetTimestampUtc": "\(stamp)" }
    """
    return Data(json.utf8)
}

/// Returns `first` once, then `fallback` forever.
private final class OneShotGrokBilling: @unchecked Sendable {
    private let lock = NSLock()
    private var value: GrokBillingFetch?
    private let fallback: GrokBillingFetch

    init(first: GrokBillingFetch, then fallback: GrokBillingFetch) {
        value = first
        self.fallback = fallback
    }

    func next() -> GrokBillingFetch {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value = nil
        return current ?? fallback
    }
}

/// Returns `first` once, then `fallback` forever.
private final class OneShotSand: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SandUsageFetch?
    private let fallback: SandUsageFetch

    init(first: SandUsageFetch, then fallback: SandUsageFetch) {
        value = first
        self.fallback = fallback
    }

    func next() -> SandUsageFetch {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value = nil
        return current ?? fallback
    }
}

private func grokBillingJSON(percent: Double, end: Date) -> GrokBillingFetch {
    let stamp = ISO8601DateFormatter().string(from: end)
    let json = """
    {"creditUsagePercent":\(percent),"currentPeriod":{"end":"\(stamp)"}}
    """
    return .usage(Data(json.utf8))
}

private final class BillingBox: @unchecked Sendable {
    var grok: GrokBillingFetch = .unavailable
    var grokFetch: GrokBillingFetch { grok }
}

@MainActor
private final class RecordingPoster: NotificationRequestPosting {
    var count = 0
    func post(_ request: UNNotificationRequest) { count += 1 }
}

private final class VersionCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var kept: [String] = []

    func add(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func remember(_ value: String) {
        lock.lock()
        kept.append(value)
        lock.unlock()
    }

    var sent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var remembered: [String] {
        lock.lock()
        defer { lock.unlock() }
        return kept
    }
}

private func cursorJWT(exp: Int) -> String {
    func part(_ json: String) -> String {
        Data(json.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return part(#"{"alg":"none"}"#) + "." + part(#"{"exp":\#(exp)}"#)
}

private func binarycookiesInt32BE(_ data: Data, _ offset: Int) -> Int {
    let bytes = [UInt8](data)
    let value = UInt32(bytes[offset]) << 24
        | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) << 8
        | UInt32(bytes[offset + 3])
    return Int(Int32(bitPattern: value))
}

private func protoVarint(_ field: Int, _ value: UInt64) -> Data {
    var bytes = protoKey(field, wire: 0)
    bytes.append(contentsOf: protoVarintValue(value))
    return Data(bytes)
}

private func protoBytes(_ field: Int, _ payload: Data) -> Data {
    var bytes = protoKey(field, wire: 2)
    bytes.append(contentsOf: protoVarintValue(UInt64(payload.count)))
    var data = Data(bytes)
    data.append(payload)
    return data
}

private func protoFixed32(_ field: Int, _ value: Float) -> Data {
    var bytes = protoKey(field, wire: 5)
    let bits = value.bitPattern
    bytes.append(UInt8(bits & 0xFF))
    bytes.append(UInt8((bits >> 8) & 0xFF))
    bytes.append(UInt8((bits >> 16) & 0xFF))
    bytes.append(UInt8((bits >> 24) & 0xFF))
    return Data(bytes)
}

private func protoKey(_ field: Int, wire: Int) -> [UInt8] {
    protoVarintValue(UInt64((field << 3) | wire))
}

private func protoVarintValue(_ value: UInt64) -> [UInt8] {
    var value = value
    var bytes: [UInt8] = []
    repeat {
        var byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        bytes.append(byte)
    } while value != 0
    return bytes
}

private func makeCursorStateDatabase(_ rows: [(String, String)]) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hotspot-cursor-state-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = directory.appendingPathComponent("state.vscdb")
    var sql = "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);"
    for (key, value) in rows {
        let escapedKey = key.replacingOccurrences(of: "'", with: "''")
        let escapedValue = value.replacingOccurrences(of: "'", with: "''")
        sql += "\nINSERT INTO ItemTable VALUES ('\(escapedKey)','\(escapedValue)');"
    }
    let create = Process()
    create.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    create.arguments = [database.path, sql]
    try create.run()
    create.waitUntilExit()
    guard create.terminationStatus == 0 else {
        try? FileManager.default.removeItem(at: directory)
        throw CocoaError(.fileWriteUnknown)
    }
    return database
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func add(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class HTTPStatusBox: @unchecked Sendable {
    var code: Int
    init(_ code: Int) { self.code = code }
}

private final class HTTPBodyBox: @unchecked Sendable {
    var data: Data
    init(_ data: Data) { self.data = data }
}

private final class TokenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> CursorTokenRead {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return .missing }
        return .token(values.removeFirst())
    }
}

private func hungCommandScript() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hotspot-hung-\(UUID().uuidString).sh")
    try "#!/bin/sh\nsleep 30\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}
