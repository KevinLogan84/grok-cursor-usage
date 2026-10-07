import AppKit
import Foundation
import SwiftUI
import Testing
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
            periodUsage: { period },
            sandUsage: { sand },
            grokBilling: { grok },
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

private func hungCommandScript() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hotspot-hung-\(UUID().uuidString).sh")
    try "#!/bin/sh\nsleep 30\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}
