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
        timeout: TimeInterval = defaultTimeout,
        captureStandardError: Bool = false
    ) -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

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

        let output = pipeText(stdout, stderr, captureStandardError: captureStandardError)
        guard process.terminationStatus == 0 || captureStandardError else {
            return Outcome(output: nil, timedOut: false, terminationStatus: process.terminationStatus)
        }
        return Outcome(output: output, timedOut: false, terminationStatus: process.terminationStatus)
    }

    private static func pipeText(_ stdout: Pipe, _ stderr: Pipe, captureStandardError: Bool) -> String? {
        let out = text(stdout.fileHandleForReading.readDataToEndOfFile())
        guard captureStandardError else { return out }
        let err = text(stderr.fileHandleForReading.readDataToEndOfFile())
        let parts = [out, err].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func text(_ data: Data) -> String? {
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
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

/// Why a Cursor dashboard call did not return usage.
enum CursorDashboardResult: Sendable, Equatable {
    case noToken
    case expired
    case success(Data)
    case failed
}

/// GetSandUsageStatus, classified so a missing Cursor sign-in is not treated
/// as "this account has no Grok Bot allowance".
enum SandUsageFetch: Sendable, Equatable {
    /// No Cursor token, or Cursor rejected it.
    case needsSignIn
    /// Signed in. The body is the GetSandUsageStatus payload.
    case payload(Data)
    /// Signed in, but the request failed for another reason.
    case failed

    static func from(_ result: CursorDashboardResult) -> SandUsageFetch {
        switch result {
        case .noToken, .expired:
            return .needsSignIn
        case .failed:
            return .failed
        case .success(let data):
            if CursorAccessToken.payloadRejectsSignIn(data) {
                return .needsSignIn
            }
            return .payload(data)
        }
    }
}

enum CursorAccessToken {
    enum State: Equatable, Sendable {
        case missing
        case expired
        case present
    }

    static func state(of token: String?, now: Date = .now) -> State {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return .missing
        }
        if let expiry = jwtExpiry(token), expiry <= now {
            return .expired
        }
        return .present
    }

    /// `exp` from a JWT-shaped Cursor token. Opaque tokens return nil.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = QuotaParsing.number(from: json["exp"]),
              exp > 1_000_000_000
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// A 200 body that is an auth failure, not a usage payload.
    static func payloadRejectsSignIn(_ data: Data) -> Bool {
        let markers = [
            "unauthenticated",
            "unauthorized",
            "invalid token",
            "token expired",
            "expired token",
            "not authenticated",
        ]
        var texts: [String] = []
        if let root = QuotaParsing.jsonObject(from: data) {
            for key in ["error", "code", "message", "status"] {
                if let text = root[key] as? String { texts.append(text) }
            }
            if let error = root["error"] as? [String: Any] {
                for key in ["code", "message", "status"] {
                    if let text = error[key] as? String { texts.append(text) }
                }
            }
        } else if let text = String(data: data, encoding: .utf8) {
            texts.append(text)
        }
        let joined = texts.joined(separator: " ").lowercased()
        return markers.contains { joined.contains($0) }
    }
}

enum CursorQuotaClient {
    static func fetchPeriodUsage() async -> Data? {
        if case .success(let data) = await postDashboard("GetCurrentPeriodUsage") {
            return data
        }
        return nil
    }

    static func fetchSandUsage() async -> SandUsageFetch {
        SandUsageFetch.from(await postDashboard("GetSandUsageStatus"))
    }

    private static func postDashboard(_ method: String) async -> CursorDashboardResult {
        let raw = await readAccessToken()
        switch CursorAccessToken.state(of: raw) {
        case .missing:
            return .noToken
        case .expired:
            return .expired
        case .present:
            break
        }
        guard let token = raw else { return .noToken }
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
              let http = response as? HTTPURLResponse
        else { return .failed }
        if http.statusCode == 401 || http.statusCode == 403 {
            return .expired
        }
        guard (200..<300).contains(http.statusCode) else { return .failed }
        return .success(data)
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

/// cli-chat-proxy billing. `.outdatedClient` is a version rejection after one retry.
enum GrokBillingFetch: Sendable, Equatable {
    case usage(Data)
    case outdatedClient
    case unavailable
}

struct GrokBillingHTTPResult: Sendable, Equatable {
    var statusCode: Int
    var body: Data
}

/// The `x-grok-client-version` header. Prefer the installed grok CLI, then
/// `cliClientVersion`. One newer retry when the proxy says the client is outdated.
enum GrokCLIVersion {
    static func headerValue(detected: String?) -> String {
        if let detected, let parsed = parse(detected) { return parsed }
        return GrokQuotaClient.cliClientVersion
    }

    static func parse(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\d+\.\d+\.\d+"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let slice = Range(match.range, in: text)
        else { return nil }
        return String(text[slice])
    }

    static func version(inPackageJSON data: Data) -> String? {
        guard let root = QuotaParsing.jsonObject(from: data),
              let raw = root["version"] as? String
        else { return nil }
        return parse(raw)
    }

    /// Installer metadata. `version` wins over `stable_version`.
    static func version(inVersionJSON data: Data) -> String? {
        guard let root = QuotaParsing.jsonObject(from: data) else { return nil }
        for key in ["version", "stable_version"] {
            if let raw = root[key] as? String, let parsed = parse(raw) {
                return parsed
            }
        }
        return nil
    }

    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        guard let left = parts(lhs), let right = parts(rhs) else { return false }
        return left > right
    }

    static func isOutdatedClient(statusCode: Int, body: Data) -> Bool {
        if statusCode == 426 { return true }
        let text = String(data: body, encoding: .utf8)?.lowercased() ?? ""
        return text.contains("outdated") && (text.contains("version") || text.contains("client"))
    }

    /// The minimum the server named, such as "update to version 1.0.41 or later".
    static func requiredVersion(in body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        let patterns = [
            #"update to version\s+(\d+\.\d+\.\d+)"#,
            #"version\s+(\d+\.\d+\.\d+)\s+or later"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges > 1,
                  let slice = Range(match.range(at: 1), in: text)
            else { continue }
            return String(text[slice])
        }
        return nil
    }

    /// One retry version, newer than `sent`. The greater of the server minimum
    /// and a detected install wins. Nil when there is nothing newer to try.
    static func retryVersion(sent: String, detected: String?, serverRequired: String?) -> String? {
        let candidates = [serverRequired, detected.flatMap { parse($0) }].compactMap { $0 }
        let newer = candidates.filter { isNewer($0, than: sent) }
        return newer.reduce(String?.none) { best, next in
            guard let best else { return next }
            return isNewer(next, than: best) ? next : best
        }
    }

    static func versionFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        GrokCLIAuth.homeDirectory(environment: environment, userHome: userHome)
            .appendingPathComponent("version.json")
    }

    static func packageJSONURLs(for executable: URL) -> [URL] {
        let resolved = executable.resolvingSymlinksInPath()
        let bin = resolved.deletingLastPathComponent()
        let parent = bin.deletingLastPathComponent()
        return [
            parent.appendingPathComponent("package.json"),
            bin.appendingPathComponent("package.json"),
            parent.appendingPathComponent("lib/node_modules/@xai-official/grok/package.json"),
        ]
    }

    /// Version from `~/.grok/version.json` (or `$GROK_HOME`), then package.json
    /// beside the grok binary, then `grok --version`. Nil when none of those exist.
    static func installedVersion(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        executables: [URL]? = nil,
        fileManager: FileManager = .default,
        run: @escaping @Sendable (URL, [String]) -> String? = { url, args in
            TimedProcess.run(
                executable: url,
                arguments: args,
                timeout: 3,
                captureStandardError: true
            ).output
        }
    ) -> String? {
        let versionFile = versionFileURL(environment: environment, userHome: userHome)
        if let data = try? Data(contentsOf: versionFile), let version = version(inVersionJSON: data) {
            return version
        }
        let binaries = executables ?? executableURLs(environment: environment, userHome: userHome)
        var commandOutput: String?
        for binary in binaries {
            let resolvedPath = binary.resolvingSymlinksInPath().path
            let exists = fileManager.fileExists(atPath: binary.path)
                || fileManager.fileExists(atPath: resolvedPath)
            guard exists else { continue }
            for packageURL in packageJSONURLs(for: binary) {
                if let data = try? Data(contentsOf: packageURL),
                   let version = version(inPackageJSON: data) {
                    return version
                }
            }
            let canRun = fileManager.isExecutableFile(atPath: binary.path)
                || fileManager.isExecutableFile(atPath: resolvedPath)
            if commandOutput == nil, canRun, let output = run(binary, ["--version"]), parse(output) != nil {
                commandOutput = output
            }
        }
        if let commandOutput, let version = parse(commandOutput) {
            return version
        }
        return nil
    }

    static func executableURLs(
        environment: [String: String],
        userHome: URL
    ) -> [URL] {
        var urls: [URL] = []
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") where !directory.isEmpty {
                urls.append(URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent("grok"))
            }
        }
        urls.append(userHome.appendingPathComponent(".grok/bin/grok"))
        urls.append(URL(fileURLWithPath: "/opt/homebrew/bin/grok"))
        urls.append(URL(fileURLWithPath: "/usr/local/bin/grok"))
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private struct Parts: Comparable {
        var major: Int
        var minor: Int
        var patch: Int

        static func == (lhs: Parts, rhs: Parts) -> Bool {
            lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
        }

        static func < (lhs: Parts, rhs: Parts) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }

    private static func parts(_ text: String) -> Parts? {
        guard let parsed = parse(text) else { return nil }
        let numbers = parsed.split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return Parts(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }
}

actor GrokCLIVersionCache {
    private var header: String?

    func current() -> String? { header }

    func set(_ version: String) { header = version }

    /// Remembers the first resolved header so later polls skip `grok --version`.
    func resolved(_ resolve: @Sendable () -> String) -> String {
        if let header { return header }
        let value = resolve()
        header = value
        return value
    }
}

enum GrokQuotaClient {
    /// Fallback `x-grok-client-version` when the installed grok CLI can't be read.
    /// This is the grok CLI release current with Grok 4.7 (`@xai-official/grok` 1.0.40).
    static let cliClientVersion = "1.0.40"

    private static let versionCache = GrokCLIVersionCache()

    static func hasSessionLogin() -> Bool {
        GrokCLIAuth.hasSessionLogin()
    }

    static func hasSignedInSession(source: GrokSignInSource = .current()) -> Bool {
        if GrokCLIAuth.hasSessionLogin() { return true }
        return source.usesGrokApp && GrokAppSession.hasSignedInCookies()
    }

    static func fetchBilling(source: GrokSignInSource = .current()) async -> GrokBillingFetch {
        let cli = await fetchCLIBilling()
        if case .usage = cli { return cli }
        if source.usesGrokApp {
            let cookies = GrokAppSession.cookies()
            if !cookies.isEmpty, let web = await GrokWebBillingClient.fetchBilling(cookies: cookies) {
                return .usage(web)
            }
        }
        return cli
    }

    /// Sends `headerVersion`, and on an outdated-client rejection retries once
    /// with a detected or server-required newer version.
    static func billingFetch(
        headerVersion: String,
        redetect: @Sendable () -> String?,
        perform: @Sendable (String) async -> GrokBillingHTTPResult?,
        remember: @Sendable (String) async -> Void = { _ in }
    ) async -> GrokBillingFetch {
        guard let first = await perform(headerVersion) else { return .unavailable }
        if (200..<300).contains(first.statusCode) {
            return .usage(first.body)
        }
        guard GrokCLIVersion.isOutdatedClient(statusCode: first.statusCode, body: first.body) else {
            return .unavailable
        }
        let detected = redetect()
        guard let retry = GrokCLIVersion.retryVersion(
            sent: headerVersion,
            detected: detected,
            serverRequired: GrokCLIVersion.requiredVersion(in: first.body)
        ) else {
            return .outdatedClient
        }
        guard let second = await perform(retry) else { return .outdatedClient }
        if (200..<300).contains(second.statusCode) {
            await remember(retry)
            return .usage(second.body)
        }
        return .outdatedClient
    }

    private static func fetchCLIBilling() async -> GrokBillingFetch {
        guard let session = await cliSession() else { return .unavailable }
        let header = await headerVersion()
        return await billingFetch(
            headerVersion: header,
            redetect: { GrokCLIVersion.installedVersion() },
            perform: { version in
                await billingHTTP(session: session, version: version)
            },
            remember: { version in
                await versionCache.set(version)
            }
        )
    }

    private static func headerVersion() async -> String {
        if let cached = await versionCache.current() { return cached }
        let resolved = GrokCLIVersion.headerValue(detected: GrokCLIVersion.installedVersion())
        await versionCache.set(resolved)
        return resolved
    }

    private static func billingHTTP(session: CLISession, version: String) async -> GrokBillingHTTPResult? {
        var request = URLRequest(
            url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        )
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue(version, forHTTPHeaderField: "x-grok-client-version")
        request.setValue("headless", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("grok-build", forHTTPHeaderField: "x-grok-client-surface")
        if let userID = session.userID, !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "x-userid")
        }
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        return GrokBillingHTTPResult(statusCode: http.statusCode, body: data)
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
