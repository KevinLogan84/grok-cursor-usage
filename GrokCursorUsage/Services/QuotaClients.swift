import Foundation
import Observation
#if canImport(Darwin)
import Darwin
#endif

/// Runs a helper process and kills it if it does not exit. sqlite3 -readonly
/// and `security find-generic-password` can block forever without this.
enum TimedProcess {
    static let defaultTimeout: TimeInterval = 2
    static let sqlite3URL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    static let securityURL = URL(fileURLWithPath: "/usr/bin/security")

    struct Outcome: Sendable, Equatable {
        var output: String?
        var timedOut: Bool
        var terminationStatus: Int32
    }

    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return Outcome(output: nil, timedOut: false, terminationStatus: -1)
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            forceStop(process)
            _ = exited.wait(timeout: .now() + 1)
            if process.isRunning {
                process.waitUntilExit()
            }
            return Outcome(output: nil, timedOut: true, terminationStatus: process.terminationStatus)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = (text?.isEmpty == false) ? text : nil
        guard process.terminationStatus == 0 else {
            return Outcome(output: nil, timedOut: false, terminationStatus: process.terminationStatus)
        }
        return Outcome(output: output, timedOut: false, terminationStatus: process.terminationStatus)
    }

    private static func forceStop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.isRunning else { return }
        #if canImport(Darwin)
        kill(process.processIdentifier, SIGKILL)
        #endif
    }
}

/// Local Cursor `state.vscdb` reads. Never log values — they can be tokens.
enum CursorStateStore {
    static func stateDatabase(
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        userHome.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
    }

    static func string(
        forKey key: String,
        database: URL,
        timeout: TimeInterval = TimedProcess.defaultTimeout,
        executable: URL = TimedProcess.sqlite3URL
    ) -> String? {
        let escaped = key.replacingOccurrences(of: "'", with: "''")
        return query(
            sql: "SELECT value FROM ItemTable WHERE key='\(escaped)' LIMIT 1;",
            database: database,
            timeout: timeout,
            executable: executable
        )
    }

    /// `key` / `value` pairs. Values may be secrets — do not log them.
    static func rows(
        sql: String,
        database: URL,
        timeout: TimeInterval = TimedProcess.defaultTimeout,
        executable: URL = TimedProcess.sqlite3URL
    ) -> [(key: String, value: String)] {
        if let json = query(
            sql: sql,
            database: database,
            json: true,
            timeout: timeout,
            executable: executable
        ) {
            let parsed = parseJSONRows(json)
            if !parsed.isEmpty { return parsed }
        }
        guard let raw = query(
            sql: sql,
            database: database,
            json: false,
            timeout: timeout,
            executable: executable
        ) else { return [] }
        return parseJSONRows(raw)
    }

    static func parseJSONRows(_ output: String) -> [(key: String, value: String)] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8)
        else { return [] }
        if let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return rows.compactMap { row in
                guard let key = row["key"] as? String else { return nil }
                let value = stringValue(row["value"]) ?? ""
                return (key, value)
            }
        }
        return []
    }

    static func keys(
        sql: String,
        database: URL,
        timeout: TimeInterval = TimedProcess.defaultTimeout,
        executable: URL = TimedProcess.sqlite3URL
    ) -> [String] {
        rows(sql: sql, database: database, timeout: timeout, executable: executable)
            .map(\.key)
            .filter { !$0.isEmpty }
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        if let dict = value as? [String: Any],
           JSONSerialization.isValidJSONObject(dict),
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return nil
    }

    /// Never copy a multi-GB `state.vscdb`. Live URI reads are the normal path.
    static let maxCopyByteCount: UInt64 = 32 * 1024 * 1024

    static func shouldCopyDatabase(byteCount: UInt64) -> Bool {
        byteCount > 0 && byteCount <= maxCopyByteCount
    }

    static func shouldCopyDatabase(_ database: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: database.path))?[.size] as? NSNumber else {
            return false
        }
        return shouldCopyDatabase(byteCount: size.uint64Value)
    }

    /// `file:<path>?mode=ro` so sqlite3 opens URI readonly without a 5GB copy.
    static func sqliteFileURI(database: URL, immutable: Bool) -> String {
        let encoded = database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? database.path
        var uri = "file:\(encoded)?mode=ro"
        if immutable {
            uri += "&immutable=1"
        }
        return uri
    }

    static func query(
        sql: String,
        database: URL,
        json: Bool = false,
        timeout: TimeInterval = TimedProcess.defaultTimeout,
        executable: URL = TimedProcess.sqlite3URL
    ) -> String? {
        let live = sqliteOutput(
            database: database,
            sql: sql,
            json: json,
            timeout: timeout,
            executable: executable,
            filename: sqliteFileURI(database: database, immutable: false)
        )
        if !live.timedOut, live.terminationStatus == 0 {
            return live.output
        }
        let frozen = sqliteOutput(
            database: database,
            sql: sql,
            json: json,
            timeout: timeout,
            executable: executable,
            filename: sqliteFileURI(database: database, immutable: true)
        )
        if !frozen.timedOut, frozen.terminationStatus == 0 {
            return frozen.output
        }
        guard shouldCopyDatabase(database),
              let copy = copyDatabaseForRead(database)
        else { return nil }
        defer { removeCopiedDatabase(copy) }
        return sqliteOutput(
            database: copy,
            sql: sql,
            json: json,
            timeout: timeout,
            executable: executable,
            filename: copy.path
        ).output
    }

    static func sqliteOutput(
        database: URL,
        sql: String,
        json: Bool = false,
        timeout: TimeInterval = TimedProcess.defaultTimeout,
        executable: URL = TimedProcess.sqlite3URL,
        filename: String? = nil
    ) -> TimedProcess.Outcome {
        guard FileManager.default.fileExists(atPath: database.path) else {
            return TimedProcess.Outcome(output: nil, timedOut: false, terminationStatus: -1)
        }
        let busyMs = max(1, Int((timeout * 1000).rounded()))
        var arguments = ["-readonly", "-cmd", ".timeout \(busyMs)"]
        if json { arguments.append("-json") }
        arguments.append(contentsOf: [filename ?? database.path, sql])
        return TimedProcess.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
    }

    private static func copyDatabaseForRead(_ database: URL) -> URL? {
        guard shouldCopyDatabase(database) else { return nil }
        let fm = FileManager.default
        let copy = fm.temporaryDirectory
            .appendingPathComponent("hotspot-cursor-state-\(UUID().uuidString).vscdb")
        try? fm.removeItem(at: copy)
        guard (try? fm.copyItem(at: database, to: copy)) != nil else { return nil }
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: database.path + suffix)
            let dest = URL(fileURLWithPath: copy.path + suffix)
            if fm.fileExists(atPath: source.path) {
                try? fm.copyItem(at: source, to: dest)
            }
        }
        return copy
    }

    private static func removeCopiedDatabase(_ copy: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: copy)
        try? fm.removeItem(at: URL(fileURLWithPath: copy.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: copy.path + "-shm"))
    }
}

enum CursorQuotaClient {
    static func fetchPeriodUsage() async -> Data? {
        await postDashboard("GetCurrentPeriodUsage")
    }

    static func fetchSandUsage() async -> Data? {
        await postDashboard("GetSandUsageStatus")
    }

    private static func postDashboard(_ method: String) async -> Data? {
        guard let token = await readAccessToken() else { return nil }
        var request = URLRequest(
            url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)")!
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }

    private static func readAccessToken() async -> String? {
        await Task.detached {
            CursorStateStore.string(
                forKey: "cursorAuth/accessToken",
                database: CursorStateStore.stateDatabase()
            )
        }.value
    }
}

/// Official grok CLI OAuth lives in `$GROK_HOME/auth.json` (default `~/.grok/auth.json`).
/// `GROK_AUTH_JSON` is an optional explicit file override. `auth.json.lock` is not a
/// credential. Grok Bot cookies and "Grok Bot Safe Storage" are never read.
enum GrokCLIAuth {
    static func homeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let raw = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return userHome.appendingPathComponent(".grok", isDirectory: true)
    }

    static func authFileURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var urls: [URL] = []
        if let explicit = environment["GROK_AUTH_JSON"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            urls.append(URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath))
        }
        urls.append(homeDirectory(environment: environment, userHome: userHome).appendingPathComponent("auth.json"))
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func sessionFields(from root: [String: Any]) -> (token: String?, refresh: String?, clientID: String?, userID: String?) {
        var token: String?
        var refresh: String?
        var clientID: String?
        var userID: String?
        func take(_ entry: [String: Any]) {
            if token == nil {
                token = (entry["key"] as? String) ?? (entry["access_token"] as? String)
            }
            if refresh == nil { refresh = entry["refresh_token"] as? String }
            if clientID == nil { clientID = entry["oidc_client_id"] as? String }
            if userID == nil {
                let candidate = (entry["user_id"] as? String) ?? (entry["userId"] as? String)
                if let candidate, !candidate.isEmpty {
                    userID = candidate
                }
            }
        }
        take(root)
        for value in root.values {
            if let entry = value as? [String: Any] {
                take(entry)
            }
        }
        return (token, refresh, clientID, userID)
    }

    static func hasSessionLogin(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        for url in authFileURLs(environment: environment, userHome: userHome) {
            guard let raw = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
            else { continue }
            let fields = sessionFields(from: root)
            if fields.token != nil || fields.refresh != nil {
                return true
            }
        }
        return false
    }
}

/// Where Grok usage is read from. Grok.app's cookie file sits in another app's
/// container, so it is only opened when the user opts in (it needs Full Disk Access).
enum GrokSignInSource: String, CaseIterable, Identifiable, Sendable {
    case cli
    case cliAndGrokApp

    static let defaultsKey = "com.grokcursorusage.grokSource"

    static func current(_ defaults: UserDefaults = .standard) -> GrokSignInSource {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .cli
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cli: "grok CLI"
        case .cliAndGrokApp: "CLI + Grok.app"
        }
    }

    var usesGrokApp: Bool { self == .cliAndGrokApp }
}

@MainActor
@Observable
final class GrokSignInSourceStore {
    var source: GrokSignInSource {
        didSet { defaults.set(source.rawValue, forKey: GrokSignInSource.defaultsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        source = GrokSignInSource.current(defaults)
    }
}

enum GrokQuotaClient {
    /// `cli-chat-proxy` version-gates billing. This is the grok CLI release
    /// current with Grok 4.7 (`@xai-official/grok` 1.0.40).
    static let cliClientVersion = "1.0.40"

    static func hasSessionLogin() -> Bool {
        GrokCLIAuth.hasSessionLogin()
    }

    static func hasSignedInSession(source: GrokSignInSource = .current()) -> Bool {
        if GrokCLIAuth.hasSessionLogin() { return true }
        return source.usesGrokApp && GrokAppSession.hasSignedInCookies()
    }

    static func fetchBilling(source: GrokSignInSource = .current()) async -> Data? {
        if let cli = await fetchCLIBilling() {
            return cli
        }
        guard source.usesGrokApp else { return nil }
        let cookies = GrokAppSession.cookies()
        guard !cookies.isEmpty else { return nil }
        return await GrokWebBillingClient.fetchBilling(cookies: cookies)
    }

    private static func fetchCLIBilling() async -> Data? {
        guard let session = await cliSession() else { return nil }
        var request = URLRequest(
            url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        )
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue(cliClientVersion, forHTTPHeaderField: "x-grok-client-version")
        request.setValue("headless", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("grok-build", forHTTPHeaderField: "x-grok-client-surface")
        if let userID = session.userID, !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "x-userid")
        }
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }

    /// A refreshed token is never written back into the CLI's `auth.json` (that file
    /// belongs to the grok CLI), so it is remembered here. Without this every
    /// poll after the stored token expired would hit auth.x.ai again,
    /// and a rotated refresh token would be lost.
    private static let refreshedTokens = RefreshedTokenCache()

    private struct CLISession: Sendable {
        var token: String
        var userID: String?
    }

    private static func cliSession() async -> CLISession? {
        for authURL in GrokCLIAuth.authFileURLs() {
            guard let raw = try? Data(contentsOf: authURL),
                  let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
            else { continue }
            let fields = GrokCLIAuth.sessionFields(from: root)
            if let refresh = fields.refresh, let clientID = fields.clientID, shouldRefresh(root: root) {
                let cached = await refreshedTokens.entry(for: refresh)
                if let cached, cached.expiresAt.timeIntervalSinceNow > 120 {
                    return CLISession(token: cached.accessToken, userID: fields.userID)
                }
                if let refreshed = await refreshAccessToken(
                    refreshToken: cached?.refreshToken ?? refresh,
                    clientID: clientID
                ) {
                    await refreshedTokens.store(refreshed, for: refresh)
                    return CLISession(token: refreshed.accessToken, userID: fields.userID)
                }
            }
            if let token = fields.token {
                return CLISession(token: token, userID: fields.userID)
            }
        }
        return nil
    }

    /// `expires_at` may sit at the root (flat auth.json) or inside a named entry.
    static func shouldRefresh(root: [String: Any], now: Date = .now) -> Bool {
        var candidates: [[String: Any]] = [root]
        candidates.append(contentsOf: root.values.compactMap { $0 as? [String: Any] })
        for entry in candidates {
            guard let expires = entry["expires_at"] as? String,
                  let date = QuotaParsing.parseISODate(expires)
            else { continue }
            if date.timeIntervalSince(now) < 120 {
                return true
            }
        }
        return false
    }

    struct RefreshedToken: Sendable, Equatable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date

        static let defaultLifetime: TimeInterval = 3600

        /// `refresh_token` in the response replaces the one we sent (rotation);
        /// `expires_in` missing means the usual one-hour token.
        static func parse(_ json: [String: Any], sentRefreshToken: String, now: Date = .now) -> RefreshedToken? {
            guard let token = json["access_token"] as? String, !token.isEmpty else { return nil }
            let lifetime = QuotaParsing.number(from: json["expires_in"]) ?? defaultLifetime
            return RefreshedToken(
                accessToken: token,
                refreshToken: (json["refresh_token"] as? String) ?? sentRefreshToken,
                expiresAt: now.addingTimeInterval(max(60, lifetime))
            )
        }
    }

    private actor RefreshedTokenCache {
        private var entries: [String: RefreshedToken] = [:]

        func entry(for fileRefreshToken: String) -> RefreshedToken? {
            entries[fileRefreshToken]
        }

        func store(_ token: RefreshedToken, for fileRefreshToken: String) {
            entries[fileRefreshToken] = token
        }
    }

    private static func refreshAccessToken(refreshToken: String, clientID: String) async -> RefreshedToken? {
        var request = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token=\(urlEncode(refreshToken))&client_id=\(urlEncode(clientID))"
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return RefreshedToken.parse(json, sentRefreshToken: refreshToken)
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
