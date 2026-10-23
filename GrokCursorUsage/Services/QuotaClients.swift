import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#endif
#if canImport(OSLog)
import os
#endif
#if canImport(Network)
@preconcurrency import Network
#endif
#if canImport(Security)
import Security
#endif

/// Runs a helper process and kills it if it does not exit. sqlite3 -readonly
/// can block forever without this. The Keychain is read with SecItem, not
/// the `security` command.
enum TimedProcess {
    static let defaultTimeout: TimeInterval = 2
    static let sqlite3URL = URL(fileURLWithPath: "/usr/bin/sqlite3")

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
    /// The only Cursor auth key this app reads. `cursorAuth/refreshToken` is never
    /// read. A `cursor-safe-storage:v1:` value is decrypted with the Keychain
    /// password. A plaintext token does not touch the Keychain.
    static let accessTokenKey = "cursorAuth/accessToken"

    static func stateDatabase(
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        userHome.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
    }

    /// Cursor's electron state file, beside `state.vscdb`. Holds
    /// `telemetry.machineId` and `telemetry.macMachineId`. It is not the
    /// access token and it is not the Keychain.
    static func storageJSON(
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        userHome.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/storage.json"
        )
    }

    static func cursorProductJSONFiles(
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/Cursor.app/Contents/Resources/app/product.json"),
            userHome.appendingPathComponent(
                "Applications/Cursor.app/Contents/Resources/app/product.json"
            ),
        ]
    }

    static func modificationDate(of database: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: database.path)
        return attributes?[.modificationDate] as? Date
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

    /// `cursorAuth/accessToken` only. A hung read is `.timedOut`, not a missing token.
    static func readAccessToken(
        database: URL,
        timeout: TimeInterval = TimedProcess.defaultTimeout,
        executable: URL = TimedProcess.sqlite3URL
    ) -> CursorTokenRead {
        let escaped = accessTokenKey.replacingOccurrences(of: "'", with: "''")
        let read = readSQL(
            sql: "SELECT value FROM ItemTable WHERE key='\(escaped)' LIMIT 1;",
            database: database,
            timeout: timeout,
            executable: executable
        )
        if read.timedOut {
            return .timedOut
        }
        guard read.terminationStatus == 0, let output = read.output, !output.isEmpty else {
            return .missing
        }
        return .token(output)
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

    private struct SQLiteRead {
        var output: String?
        var timedOut: Bool
        var terminationStatus: Int32
        /// True when the value came from a temporary copy. A non-zero status on
        /// that path can still carry output, matching the previous `query` behavior.
        var copied: Bool
    }

    static func query(
        sql: String,
        database: URL,
        json: Bool = false,
        timeout: TimeInterval = TimedProcess.defaultTimeout,
        executable: URL = TimedProcess.sqlite3URL
    ) -> String? {
        let read = readSQL(
            sql: sql,
            database: database,
            json: json,
            timeout: timeout,
            executable: executable
        )
        if read.timedOut { return nil }
        if read.terminationStatus != 0, !read.copied { return nil }
        return read.output
    }

    private static func readSQL(
        sql: String,
        database: URL,
        json: Bool = false,
        timeout: TimeInterval = TimedProcess.defaultTimeout,
        executable: URL = TimedProcess.sqlite3URL
    ) -> SQLiteRead {
        let live = sqliteOutput(
            database: database,
            sql: sql,
            json: json,
            timeout: timeout,
            executable: executable,
            filename: sqliteFileURI(database: database, immutable: false)
        )
        if !live.timedOut, live.terminationStatus == 0 {
            return SQLiteRead(
                output: live.output,
                timedOut: false,
                terminationStatus: 0,
                copied: false
            )
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
            return SQLiteRead(
                output: frozen.output,
                timedOut: false,
                terminationStatus: 0,
                copied: false
            )
        }
        let timedOut = live.timedOut || frozen.timedOut
        guard shouldCopyDatabase(database),
              let copy = copyDatabaseForRead(database)
        else {
            return SQLiteRead(
                output: nil,
                timedOut: timedOut,
                terminationStatus: frozen.terminationStatus,
                copied: false
            )
        }
        defer { removeCopiedDatabase(copy) }
        let copied = sqliteOutput(
            database: copy,
            sql: sql,
            json: json,
            timeout: timeout,
            executable: executable,
            filename: copy.path
        )
        if copied.timedOut {
            return SQLiteRead(
                output: nil,
                timedOut: true,
                terminationStatus: copied.terminationStatus,
                copied: true
            )
        }
        return SQLiteRead(
            output: copied.output,
            timedOut: false,
            terminationStatus: copied.terminationStatus,
            copied: true
        )
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

/// One read of `cursorAuth/accessToken`. A timeout is not a missing key.
enum CursorTokenRead: Sendable, Equatable {
    case token(String)
    case missing
    case timedOut
    /// The user cancelled the Allow sheet, or macOS refused the Keychain prompt.
    case keychainDenied
    /// `Cursor Safe Storage` has neither `Cursor Key` nor the legacy `Cursor` account.
    case keychainMissing
    /// The Keychain item was read, but the envelope did not decrypt.
    case keychainLocked
}

/// Why a Cursor dashboard call did not return usage.
enum CursorDashboardResult: Sendable, Equatable {
    /// `state.vscdb` has no access token.
    case noToken
    /// JWT `exp` has passed, or Cursor returned 401/403. Opaque tokens have no
    /// `exp`, so a 401/403 is what marks them expired. The rejection is present
    /// when Cursor itself answered.
    case expired(CursorServerRejection?)
    case success(Data)
    /// Network failure, a non-auth HTTP status, or the refresh deadline.
    case failed(CursorServerRejection?)
    /// Reading `state.vscdb` timed out.
    case timedOut
    /// The Allow sheet was cancelled or macOS refused it.
    case keychainDenied
    /// Cursor's safe-storage Keychain item is not on this Mac.
    case keychainMissing
    /// The Keychain password did not decrypt the stored access token.
    case keychainLocked
}

enum CursorDecodedBody: Sendable, Equatable {
    case success(Data)
    case failure(String)
}

struct CursorHTTPResponse: Sendable, Equatable {
    var statusCode: Int
    var body: Data
    var contentType: String? = nil
    var contentEncoding: String? = nil
}

/// GetSandUsageStatus, classified so a missing Cursor sign-in is not treated
/// as "this account has no Grok Bot allowance".
enum SandUsageFetch: Sendable, Equatable {
    /// No `cursorAuth/accessToken` on this Mac.
    case noToken
    /// Cursor rejected the sign-in, or the JWT `exp` has passed.
    case expired(CursorServerRejection?)
    /// Signed in. The body is the GetSandUsageStatus payload.
    case payload(Data)
    /// The request failed, or the refresh deadline passed first.
    case failed(CursorServerRejection?)
    /// Reading Cursor's state database timed out.
    case timedOut
    /// The Allow sheet was cancelled or macOS refused it.
    case keychainDenied
    /// Cursor's safe-storage Keychain item is not on this Mac.
    case keychainMissing
    /// The Keychain password did not decrypt the stored access token.
    case keychainLocked

    static func from(_ result: CursorDashboardResult) -> SandUsageFetch {
        switch result {
        case .noToken:
            return .noToken
        case .expired(let rejection):
            return .expired(rejection)
        case .failed(let rejection):
            return .failed(rejection)
        case .timedOut:
            return .timedOut
        case .keychainDenied:
            return .keychainDenied
        case .keychainMissing:
            return .keychainMissing
        case .keychainLocked:
            return .keychainLocked
        case .success(let data):
            if CursorAccessToken.payloadRejectsSignIn(data) {
                return .expired(
                    CursorServerRejection(
                        statusCode: 200,
                        serverMessage: CursorDashboardAuth.serverMessage(from: data, token: "")
                    )
                )
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

/// In-memory access token. `state.vscdb` is not read on every refresh.
/// Re-read when its modification time changes, and once after Cursor rejects
/// the token. A later 401 at that same modification time reuses the
/// confirmation read. A timed-out read is not cached.
actor CursorAccessTokenCache {
    private struct Entry {
        var mtime: Date?
        var read: CursorTokenRead
        /// True after a rejection re-read for this modification time.
        var confirmed: Bool
    }

    private struct Inflight {
        var id: UUID
        var mtime: Date?
        var force: Bool
        var task: Task<CursorTokenRead, Never>
    }

    private var entry: Entry?
    private var inflight: Inflight?
    private var generation = 0

    func read(
        mtime: Date?,
        force: Bool,
        load: @escaping @Sendable () async -> CursorTokenRead
    ) async -> CursorTokenRead {
        if !force, let entry, entry.mtime == mtime {
            return entry.read
        }
        if force, let entry, entry.confirmed, entry.mtime == mtime {
            return entry.read
        }
        if let inflight, inflight.mtime == mtime, inflight.force == force {
            return await inflight.task.value
        }
        generation += 1
        let ticket = generation
        let id = UUID()
        let task = Task { await load() }
        inflight = Inflight(id: id, mtime: mtime, force: force, task: task)
        let read = await task.value
        guard ticket == generation else { return read }
        if self.inflight?.id == id {
            self.inflight = nil
        }
        if case .timedOut = read {
            return read
        }
        entry = Entry(mtime: mtime, read: read, confirmed: force)
        return read
    }
}

/// Unified log for dashboard rejections. `log stream` filters on these.
enum CursorDashboardLog {
    static let subsystem = "com.grokcursorusage.app"
    static let category = "cursor-dashboard"

    #if canImport(OSLog)
    fileprivate static let logger = Logger(subsystem: subsystem, category: category)
    #endif
}

/// Headers Cursor 3.27.6 attaches to every `DashboardService` call.
///
/// The running IDE sends these from `cursor-always-local`, not from the
/// workbench's startup channel. The backend transport is HTTP/1.1
/// (`useHttp2: false`) to `https://api2.cursor.sh`, with an empty protobuf
/// body (`Content-Type: application/proto`, `Content-Length: 0`) and
/// `User-Agent: connect-es/1.6.1`. `x-cursor-checksum` is still the time
/// cipher from `L8e`: `Math.floor(Date.now() / 1e6)`, JavaScript `>>`, then
/// the machine id. The machine id is sha256 of the IOPlatformUUID, and the
/// mac id is sha256 of the first eligible MAC. `storage.json` is only the
/// fallback. The refresh token is not read. A safe-storage access token is
/// decrypted with the Keychain password; a plaintext token is not.
enum CursorDashboardAuth {
    static let fallbackClientVersion = "3.27.6"
    /// `@connectrpc/connect` 1.6.1, the copy `cursor-always-local` actually sends.
    /// The workbench bundle's literal `CONNECT_ES_USER_AGENT` is only the startup channel.
    static let connectUserAgent = "connect-es/1.6.1"
    static let machineIDKey = "telemetry.machineId"
    static let macMachineIDKey = "telemetry.macMachineId"
    /// 32 random bytes, hex, stable for this process. Same role as `clientKey`.
    static let processClientKey: String = randomHex(32)

    struct Profile: Sendable, Equatable {
        var version: String
        var machineId: String?
        var macMachineId: String?
        var operatingSystem: String
        var architecture: String
        var timeZone: String?
        /// `os.totalmem()` as a decimal string. Omitted when unknown.
        var deviceMemory: String? = nil
    }

    static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x64"
        #else
        "x64"
        #endif
    }

    /// Decimal byte count, matching `String(Math.round(os.totalmem()))` when it is 1–16 digits.
    static var currentDeviceMemory: String? {
        let bytes = ProcessInfo.processInfo.physicalMemory
        guard bytes > 0 else { return nil }
        let text = String(bytes)
        guard (1...16).contains(text.count), text.allSatisfy(\.isNumber) else { return nil }
        return text
    }

    static func profile(
        storageFile: URL,
        productFiles: [URL],
        operatingSystem: String = "darwin",
        architecture: String = currentArchitecture,
        timeZone: String? = TimeZone.current.identifier,
        fallbackVersion: String = fallbackClientVersion,
        deviceMemory: String? = currentDeviceMemory,
        liveMachineID: String? = nil,
        liveMacMachineID: String? = nil,
        resolveLiveIDs: Bool = true
    ) -> Profile {
        let stored = machineIDs(from: (try? Data(contentsOf: storageFile)) ?? Data())
        let machineId: String?
        let macMachineId: String?
        if resolveLiveIDs {
            machineId = liveMachineID ?? self.liveMachineID() ?? stored.machineId
            macMachineId = liveMacMachineID ?? self.liveMacMachineID() ?? stored.macMachineId
        } else {
            machineId = stored.machineId
            macMachineId = stored.macMachineId
        }
        return Profile(
            version: productFiles.lazy.compactMap { url in
                (try? Data(contentsOf: url)).flatMap(installedVersion(from:))
            }.first ?? fallbackVersion,
            machineId: machineId,
            macMachineId: macMachineId,
            operatingSystem: operatingSystem,
            architecture: architecture,
            timeZone: timeZone,
            deviceMemory: deviceMemory
        )
    }

    static func machineIDs(from data: Data) -> (machineId: String?, macMachineId: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        return (text(root[machineIDKey]), text(root[macMachineIDKey]))
    }

    static func installedVersion(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return text(root["version"])
    }

    /// Same bytes as Cursor's `TR_` plus JavaScript `>>` on `Date.now()/1e6`.
    static func checksum(machineId: String, macMachineId: String?, at now: Date) -> String {
        let millis = Int64((now.timeIntervalSince1970 * 1000).rounded(.towardZero))
        let units = millis / 1_000_000
        var bytes = [40, 32, 24, 16, 8, 0].map { shift in
            UInt8(javaScriptRightShift(units, by: shift) & 0xFF)
        }
        var rolling = 165
        for index in bytes.indices {
            let mixed = ((Int(bytes[index]) ^ rolling) + (index % 256)) & 0xFF
            bytes[index] = UInt8(mixed)
            rolling = mixed
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        if let macMachineId, !macMachineId.isEmpty {
            return encoded + machineId + "/" + macMachineId
        }
        return encoded + machineId
    }

    static func urlRequest(
        method: String,
        token: String,
        profile: Profile,
        now: Date = .now,
        requestID: String = UUID().uuidString,
        traceParent: String? = nil,
        clientKey: String? = nil
    ) -> URLRequest {
        let requestID = requestID.lowercased()
        var request = URLRequest(
            url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)")!
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(connectUserAgent, forHTTPHeaderField: "User-Agent")
        // connect-es joins the names with a comma and no space: gzip then br.
        request.setValue("gzip,br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue(profile.version, forHTTPHeaderField: "x-cursor-client-version")
        request.setValue("ide", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue("editor", forHTTPHeaderField: "x-cursor-client-layout")
        request.setValue(profile.operatingSystem, forHTTPHeaderField: "x-cursor-client-os")
        request.setValue(profile.architecture, forHTTPHeaderField: "x-cursor-client-arch")
        request.setValue("desktop", forHTTPHeaderField: "x-cursor-client-device-type")
        if let memory = profile.deviceMemory, (1...16).contains(memory.count), memory.allSatisfy(\.isNumber) {
            request.setValue(memory, forHTTPHeaderField: "x-cursor-client-device-memory")
        }
        request.setValue("implicit-false", forHTTPHeaderField: "x-ghost-mode")
        request.setValue("false", forHTTPHeaderField: "x-new-onboarding-completed")
        request.setValue(clientKey ?? processClientKey, forHTTPHeaderField: "x-client-key")
        request.setValue(requestID, forHTTPHeaderField: "x-request-id")
        request.setValue("Root=\(requestID)", forHTTPHeaderField: "x-amzn-trace-id")
        request.setValue("true", forHTTPHeaderField: "x-cursor-streaming")
        request.setValue(traceParent ?? self.traceParent(), forHTTPHeaderField: "traceparent")
        // The IDE's cookie jar stores a path-scoped cookie and then asks for the
        // origin, so the Cookie header it sets is empty. Do not send a token prefix.
        request.setValue("", forHTTPHeaderField: "Cookie")
        if let timeZone = profile.timeZone, !timeZone.isEmpty {
            request.setValue(timeZone, forHTTPHeaderField: "x-cursor-timezone")
        }
        if let machineId = profile.machineId, !machineId.isEmpty {
            request.setValue(
                checksum(machineId: machineId, macMachineId: profile.macMachineId, at: now),
                forHTTPHeaderField: "x-cursor-checksum"
            )
        }
        request.httpBody = Data()
        request.timeoutInterval = 20
        return request
    }

    /// `00-<32 hex>-<16 hex>-00`. Flags stay `00` when there is no sampled span.
    static func traceParent(traceID: String? = nil, spanID: String? = nil) -> String {
        "00-\(traceID ?? randomHex(16))-\(spanID ?? randomHex(8))-00"
    }

    static func randomHex(_ byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<byteCount).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }

    /// JavaScript `>>`: ToInt32, then an arithmetic shift of `count & 31`.
    private static func javaScriptRightShift(_ value: Int64, by count: Int) -> Int {
        let int32 = Int32(truncatingIfNeeded: value)
        let masked = count & 31
        if masked == 0 { return Int(int32) }
        return Int(int32 >> masked)
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// First line after `IOPlatformUUID`, with `=`, quotes, and whitespace removed, then lowercased.
    /// Dashes in the UUID stay. This matches Cursor's `Let()` on darwin.
    static func platformUUID(from ioregText: String) -> String? {
        guard let marker = ioregText.range(of: "IOPlatformUUID") else { return nil }
        let line = ioregText[marker.upperBound...].split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first ?? ""
        var cleaned = ""
        for character in line {
            if character == "=" || character == "\"" || character.isWhitespace { continue }
            cleaned.append(character)
        }
        let uuid = cleaned.lowercased()
        return uuid.isEmpty ? nil : uuid
    }

    /// Node `os.networkInterfaces()` order, lowercased, dashes turned into colons.
    /// Only `00:00:00:00:00:00`, `ff:ff:ff:ff:ff:ff`, and `ac:de:48:00:11:22` are skipped.
    static func firstEligibleMAC(_ addresses: [String]) -> String? {
        let blocked: Set<String> = [
            "00:00:00:00:00:00",
            "ff:ff:ff:ff:ff:ff",
            "ac:de:48:00:11:22",
        ]
        for raw in addresses {
            let mac = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: ":")
            if mac.isEmpty || blocked.contains(mac) { continue }
            return mac
        }
        return nil
    }

    static func sha256Hex(_ text: String) -> String {
        CursorSHA256.hex(Data(text.utf8))
    }

    /// sha256 of the cleaned IOPlatformUUID. Nil when `ioreg` does not answer.
    static func liveMachineID() -> String? {
        #if canImport(Darwin)
        let outcome = TimedProcess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/ioreg"),
            arguments: ["-rd1", "-c", "IOPlatformExpertDevice"],
            timeout: 2
        )
        guard let output = outcome.output, let uuid = platformUUID(from: output) else { return nil }
        return sha256Hex(uuid)
        #else
        return nil
        #endif
    }

    /// sha256 of the first eligible MAC, in `getifaddrs` order.
    static func liveMacMachineID() -> String? {
        #if canImport(Darwin)
        guard let mac = firstEligibleMAC(localMACAddresses()) else { return nil }
        return sha256Hex(mac)
        #else
        return nil
        #endif
    }

    #if canImport(Darwin)
    static func localMACAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let current = cursor {
            if let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) {
                let dl = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_dl.self).pointee
                if dl.sdl_alen == 6 {
                    // sockaddr_dl: 8 bytes, then the interface name, then the address.
                    let raw = UnsafeRawPointer(sa).advanced(by: 8 + Int(dl.sdl_nlen))
                    let bytes = raw.assumingMemoryBound(to: UInt8.self)
                    let mac = (0..<6).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":")
                    addresses.append(mac)
                }
            }
            cursor = current.pointee.ifa_next
        }
        return addresses
    }
    #endif

    static func serverMessage(from body: Data, token: String) -> String {
        let raw: String
        if let root = QuotaParsing.jsonObject(from: body) {
            if let text = connectErrorText(root) {
                raw = text
            } else if isUsagePayload(root) {
                // A 401 can still carry the previous planUsage body. That is not
                // Cursor's error text.
                return ""
            } else if let text = String(data: body, encoding: .utf8), !text.isEmpty, !looksBinary(text) {
                raw = text
            } else {
                return ""
            }
        } else if let text = String(data: body, encoding: .utf8), !text.isEmpty, !looksBinary(text) {
            raw = text
        } else {
            return ""
        }
        return clip(redact(raw, token: token), limit: 160)
    }

    static func loggedRejection(_ response: CursorHTTPResponse, token: String) -> CursorServerRejection {
        let rejection = CursorServerRejection(
            statusCode: response.statusCode,
            serverMessage: serverMessage(from: response.body, token: token)
        )
        recordRejection(rejection)
        return rejection
    }

    /// Status and server text that `recordRejection` sends to `os.Logger`.
    /// Bearer secrets and long `cursor-` values are replaced here. The token is not logged.
    static func unifiedLogFields(_ rejection: CursorServerRejection) -> (statusCode: Int, message: String) {
        (rejection.statusCode, redact(rejection.serverMessage, token: ""))
    }

    static func recordRejection(_ rejection: CursorServerRejection) {
        #if canImport(OSLog)
        let fields = unifiedLogFields(rejection)
        let status = fields.statusCode
        let message = fields.message
        // `.public` keeps `log stream` from replacing the status and the
        // redacted server text with `<private>`. The token is not in either value.
        CursorDashboardLog.logger.log(
            level: .error,
            "[cursor-dashboard] HTTP \(status, privacy: .public): \(message, privacy: .public)"
        )
        #endif
    }

    /// JSON the existing bar parsers already understand. An empty protobuf is `{}`.
    /// A JSON body is left alone. A protobuf body is decoded. Nil means the body was unreadable.
    static func usageJSON(method: String, body: Data) -> Data? {
        if body.isEmpty { return Data("{}".utf8) }
        if let text = String(data: body, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                return body
            }
        }
        switch method {
        case "GetCurrentPeriodUsage":
            return periodUsageJSON(from: body)
        case "GetSandUsageStatus":
            return sandUsageJSON(from: body)
        default:
            return nil
        }
    }

    static func decodedBody(_ response: CursorHTTPResponse) -> CursorDecodedBody {
        let encoding = response.contentEncoding?.lowercased() ?? ""
        if encoding.contains("gzip") {
            guard let plain = gunzip(response.body) else {
                return .failure("Cursor's response was gzip and could not be read.")
            }
            return .success(plain)
        }
        if encoding.contains("br") {
            guard let plain = brotliDecode(response.body) else {
                return .failure("Cursor's response was brotli and could not be read.")
            }
            return .success(plain)
        }
        return .success(response.body)
    }

    static func http1Message(for request: URLRequest) -> Data {
        guard let url = request.url, let host = url.host else { return Data() }
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }
        var lines = ["\(request.httpMethod ?? "POST") \(path) HTTP/1.1", "Host: \(host)"]
        let preferred = [
            "Content-Type",
            "Connect-Protocol-Version",
            "User-Agent",
            "Accept-Encoding",
            "Content-Length",
            "Authorization",
            "x-cursor-checksum",
            "x-cursor-client-version",
            "x-cursor-client-type",
            "x-cursor-client-layout",
            "x-cursor-client-os",
            "x-cursor-client-arch",
            "x-cursor-client-device-type",
            "x-cursor-client-device-memory",
            "x-ghost-mode",
            "x-new-onboarding-completed",
            "x-client-key",
            "x-cursor-timezone",
            "x-request-id",
            "x-amzn-trace-id",
            "x-cursor-streaming",
            "traceparent",
        ]
        var seen = Set<String>()
        for name in preferred {
            guard let value = request.value(forHTTPHeaderField: name) else { continue }
            lines.append("\(name): \(value)")
            seen.insert(name.lowercased())
        }
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        lines.append("Cookie: \(cookie)")
        seen.insert("cookie")
        let fields = request.allHTTPHeaderFields ?? [:]
        for name in fields.keys.sorted() {
            let key = name.lowercased()
            if seen.contains(key) || key == "cookie" { continue }
            if let value = request.value(forHTTPHeaderField: name) {
                lines.append("\(name): \(value)")
            }
        }
        if !seen.contains("content-length") {
            lines.append("Content-Length: \(request.httpBody?.count ?? 0)")
        }
        lines.append("Connection: close")
        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(Data("\r\n\r\n".utf8))
        if let body = request.httpBody {
            data.append(body)
        }
        return data
    }

    static func http1MessageIsComplete(_ data: Data) -> Bool {
        guard let split = headerSplit(data) else { return false }
        let headers = headerFields(split.header)
        let rest = data[split.bodyStart...]
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return decodeChunked(Data(rest)) != nil
        }
        if let lengthText = headers["content-length"], let length = Int(lengthText), length >= 0 {
            return rest.count >= length
        }
        return false
    }

    static func parseHTTP1(_ data: Data) -> CursorHTTPResponse? {
        guard let split = headerSplit(data) else { return nil }
        let lines = split.header.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let status = lines.first, status.hasPrefix("HTTP/1.") else { return nil }
        let parts = status.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
        let headers = headerFields(split.header)
        let rest = Data(data[split.bodyStart...])
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = decodeChunked(rest) else { return nil }
            body = decoded
        } else if let lengthText = headers["content-length"], let length = Int(lengthText), length >= 0 {
            guard rest.count >= length else { return nil }
            body = Data(rest.prefix(length))
        } else {
            body = rest
        }
        return CursorHTTPResponse(
            statusCode: code,
            body: body,
            contentType: headers["content-type"],
            contentEncoding: headers["content-encoding"]
        )
    }

    private static func periodUsageJSON(from data: Data) -> Data? {
        guard let root = protoFields(data) else { return nil }
        var object: [String: Any] = [:]
        if let start = protoInt64(protoFirst(root, 1)) {
            object["billingCycleStart"] = NSNumber(value: start)
        }
        if let end = protoInt64(protoFirst(root, 2)) {
            object["billingCycleEnd"] = NSNumber(value: end)
        }
        if let planBytes = protoFirst(root, 3)?.bytes, let plan = protoFields(planBytes) {
            var planObject: [String: Any] = [:]
            if let auto = protoFirst(plan, 12)?.doubleValue {
                planObject["autoPercentUsed"] = NSNumber(value: auto)
            }
            if let api = protoFirst(plan, 13)?.doubleValue {
                planObject["apiPercentUsed"] = NSNumber(value: api)
            }
            object["planUsage"] = planObject
        }
        if let message = protoString(protoFirst(root, 11)) {
            object["autoModelSelectedDisplayMessage"] = message
        }
        if let message = protoString(protoFirst(root, 12)) {
            object["namedModelSelectedDisplayMessage"] = message
        }
        return jsonData(object)
    }

    private static func sandUsageJSON(from data: Data) -> Data? {
        guard let root = protoFields(data) else { return nil }
        var object: [String: Any] = [:]
        if let start = timestampISO(protoFirst(root, 1)?.bytes) {
            object["currentPeriodStart"] = start
        }
        if let reset = timestampISO(protoFirst(root, 2)?.bytes) {
            object["nextResetTimestampUtc"] = reset
        }
        let limitZero = protoFirst(root, 4)?.varint == 1
        if let percent = protoFirst(root, 3)?.doubleValue {
            object["usagePercent"] = NSNumber(value: percent)
        } else if limitZero {
            object["usagePercent"] = NSNumber(value: 0)
        }
        if limitZero {
            object["enabled"] = NSNumber(value: false)
        }
        if let label = protoString(protoFirst(root, 15)) ?? protoString(protoFirst(root, 17)) {
            object["planName"] = label
        }
        return jsonData(object)
    }

    private struct ProtoField {
        var number: Int
        var varint: UInt64?
        var doubleValue: Double?
        var bytes: Data?
    }

    private static func protoFields(_ data: Data) -> [ProtoField]? {
        let bytes = [UInt8](data)
        var fields: [ProtoField] = []
        var index = 0
        while index < bytes.count {
            guard let key = readVarint(bytes, index: &index), key != 0 else { return nil }
            let field = Int(key >> 3)
            let wire = key & 0x07
            guard field > 0 else { return nil }
            switch wire {
            case 0:
                guard let value = readVarint(bytes, index: &index) else { return nil }
                fields.append(ProtoField(number: field, varint: value, doubleValue: nil, bytes: nil))
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                let bits = bytes[index..<(index + 8)].enumerated().reduce(UInt64(0)) { partial, item in
                    partial | (UInt64(item.element) << (UInt64(item.offset) * 8))
                }
                index += 8
                fields.append(
                    ProtoField(
                        number: field,
                        varint: nil,
                        doubleValue: Double(bitPattern: bits),
                        bytes: nil
                    )
                )
            case 2:
                guard let length = readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else { return nil }
                let end = index + Int(length)
                let payload = Data(bytes[index..<end])
                index = end
                fields.append(ProtoField(number: field, varint: nil, doubleValue: nil, bytes: payload))
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                index += 4
            default:
                return nil
            }
        }
        return fields
    }

    private static func protoFirst(_ fields: [ProtoField], _ number: Int) -> ProtoField? {
        fields.first { $0.number == number }
    }

    private static func protoInt64(_ field: ProtoField?) -> Int64? {
        guard let value = field?.varint else { return nil }
        return Int64(bitPattern: value)
    }

    private static func protoString(_ field: ProtoField?) -> String? {
        guard let bytes = field?.bytes, let text = String(data: bytes, encoding: .utf8), !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func timestampISO(_ data: Data?) -> String? {
        guard let data, let fields = protoFields(data), let seconds = protoInt64(protoFirst(fields, 1)), seconds > 0 else {
            return nil
        }
        let nanos = protoInt64(protoFirst(fields, 2)) ?? 0
        let date = Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = nanos > 0
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var read = 0
        while index < bytes.count, read < 10 {
            let byte = bytes[index]
            index += 1
            read += 1
            if shift == 63, byte > 1 { return nil }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func jsonData(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// GetCurrentPeriodUsage / GetSandUsageStatus success JSON, not a Connect error.
    private static func isUsagePayload(_ root: [String: Any]) -> Bool {
        if root["planUsage"] != nil { return true }
        if root["billingCycleStart"] != nil || root["billingCycleEnd"] != nil { return true }
        if root["autoPercentUsed"] != nil || root["apiPercentUsed"] != nil { return true }
        if root["usagePercent"] != nil { return true }
        if root["currentPeriodStart"] != nil || root["nextResetTimestampUtc"] != nil { return true }
        return false
    }

    private static func connectErrorText(_ root: [String: Any]) -> String? {
        var code: String?
        var message: String?
        func take(_ dict: [String: Any]) {
            if code == nil, let value = dict["code"] as? String, !value.isEmpty { code = value }
            if message == nil, let value = dict["message"] as? String, !value.isEmpty { message = value }
            if message == nil, let value = dict["error"] as? String, !value.isEmpty { message = value }
        }
        take(root)
        if let nested = root["error"] as? [String: Any] { take(nested) }
        switch (code, message) {
        case let (code?, message?) where code != message:
            return "\(code): \(message)"
        case let (_, message?):
            return message
        case let (code?, nil):
            return code
        default:
            return nil
        }
    }

    private static func redact(_ text: String, token: String) -> String {
        var output = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if token.count >= 8 {
            output = output.replacingOccurrences(of: token, with: "[redacted]")
        }
        output = redactBearer(output)
        output = redactCursorPrefixed(output)
        return output
    }

    private static func redactBearer(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        let needle = "Bearer "
        while index < text.endIndex {
            if text[index...].hasPrefix(needle) {
                let secretStart = text.index(index, offsetBy: needle.count)
                var cursor = secretStart
                while cursor < text.endIndex, !text[cursor].isWhitespace {
                    cursor = text.index(after: cursor)
                }
                if text[secretStart..<cursor].count >= 8 {
                    result += "Bearer [redacted]"
                    index = cursor
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func redactCursorPrefixed(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        let needle = "cursor-"
        while index < text.endIndex {
            if text[index...].hasPrefix(needle) {
                var cursor = text.index(index, offsetBy: needle.count)
                var extra = 0
                while cursor < text.endIndex {
                    let character = text[cursor]
                    let allowed = character.isLetter || character.isNumber || character == "_" || character == "-"
                    if !allowed { break }
                    extra += 1
                    cursor = text.index(after: cursor)
                }
                if extra >= 12 {
                    result += "[redacted]"
                    index = cursor
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func looksBinary(_ text: String) -> Bool {
        let controls = text.unicodeScalars.filter { scalar in
            scalar.value < 32 && scalar.value != 9 && scalar.value != 10 && scalar.value != 13
        }
        return !controls.isEmpty
    }

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 3)) + "..."
    }

    private static func gunzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        return inflate(data, executable: "/usr/bin/gzip", arguments: ["-dc"])
    }

    private static func brotliDecode(_ data: Data) -> Data? {
        let candidates = ["/usr/bin/brotli", "/opt/homebrew/bin/brotli", "/usr/local/bin/brotli"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if let decoded = inflate(data, executable: path, arguments: ["-d", "-c"]) {
                return decoded
            }
        }
        return nil
    }

    private static func inflate(_ data: Data, executable: String, arguments: [String]) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        stdin.fileHandleForWriting.write(data)
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return output
    }

    private static func headerSplit(_ data: Data) -> (header: String, bodyStart: Data.Index)? {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: marker),
              let header = String(data: data[..<range.lowerBound], encoding: .isoLatin1)
        else { return nil }
        return (header, range.upperBound)
    }

    private static func headerFields(_ header: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in header.split(separator: "\r\n", omittingEmptySubsequences: false).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                fields[name] = String(value)
            }
        }
        return fields
    }

    private static func decodeChunked(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var index = 0
        var body = Data()
        while index < bytes.count {
            guard let lineEnd = crlf(bytes, from: index) else { return nil }
            let line = String(bytes: bytes[index..<lineEnd], encoding: .ascii) ?? ""
            let sizeText = line.split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { return nil }
            index = lineEnd + 2
            if size == 0 { return body }
            guard index + size + 2 <= bytes.count else { return nil }
            body.append(contentsOf: bytes[index..<(index + size)])
            index += size
            guard bytes[index] == 13, bytes[index + 1] == 10 else { return nil }
            index += 2
        }
        return nil
    }

    private static func crlf(_ bytes: [UInt8], from index: Int) -> Int? {
        var cursor = index
        while cursor + 1 < bytes.count {
            if bytes[cursor] == 13, bytes[cursor + 1] == 10 { return cursor }
            cursor += 1
        }
        return nil
    }

}

/// SHA-256 of the IOPlatformUUID and the MAC address. Cursor stores those digests as hex.
enum CursorSHA256 {
    static func hex(_ data: Data) -> String {
        digest(data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ message: Data) -> [UInt8] {
        var hash: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let table: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var bytes = [UInt8](message)
        let bitLength = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] = (UInt32(bytes[start]) << 24)
                    | (UInt32(bytes[start + 1]) << 16)
                    | (UInt32(bytes[start + 2]) << 8)
                    | UInt32(bytes[start + 3])
            }
            for index in 16..<64 {
                let s0 = rotate(words[index - 15], 7) ^ rotate(words[index - 15], 18) ^ (words[index - 15] >> 3)
                let s1 = rotate(words[index - 2], 17) ^ rotate(words[index - 2], 19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
            var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choose = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choose &+ table[index] &+ words[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
        }
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in hash {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}

enum CursorQuotaClient {
    /// Shared by period usage and Grok Bot so one refresh reads the database once.
    private static let tokenCache = CursorAccessTokenCache()

    static func fetchPeriodUsage() async -> CursorDashboardResult {
        await fetchDashboard(method: "GetCurrentPeriodUsage", cache: tokenCache)
    }

    static func fetchSandUsage() async -> SandUsageFetch {
        SandUsageFetch.from(
            await fetchDashboard(method: "GetSandUsageStatus", cache: tokenCache)
        )
    }

    /// Lets the next Refresh show the Allow sheet after a denial. The cached
    /// password is kept, so an Allow that already succeeded is not asked again.
    static func allowKeychainPrompt() async {
        await CursorSafeStorageSecrets.shared.allowPromptAgain()
    }

    static func fetchDashboard(
        method: String,
        cache: CursorAccessTokenCache,
        database: URL = CursorStateStore.stateDatabase(),
        now: Date = .now,
        readToken: (@Sendable (URL) async -> CursorTokenRead)? = nil,
        perform: (@Sendable (String) async -> CursorHTTPResponse?)? = nil,
        keychainPassword: (@Sendable () async -> CursorKeychainPasswordResult)? = nil,
        secrets: CursorSafeStorageSecrets = .shared
    ) async -> CursorDashboardResult {
        let loadToken = readToken ?? { url in
            await Task.detached {
                CursorStateStore.readAccessToken(database: url)
            }.value
        }
        let send = perform ?? { token in
            await dashboardHTTP(method: method, token: token)
        }
        let lookup: @Sendable () async -> CursorKeychainPasswordResult = keychainPassword ?? {
            await CursorSafeStorage.copyPassword()
        }

        func load(force: Bool) async -> CursorTokenRead {
            let mtime = CursorStateStore.modificationDate(of: database)
            return await cache.read(mtime: mtime, force: force) {
                await loadToken(database)
            }
        }

        func opened(_ read: CursorTokenRead) async -> CursorTokenRead {
            guard case .token(let stored) = read, CursorSafeStorage.isEnvelope(stored) else {
                return read
            }
            return await secrets.unlock(read, lookup: lookup)
        }

        func finish(_ read: CursorTokenRead, allowReread: Bool) async -> CursorDashboardResult {
            switch read {
            case .timedOut:
                return .timedOut
            case .missing:
                return .noToken
            case .keychainDenied:
                return .keychainDenied
            case .keychainMissing:
                return .keychainMissing
            case .keychainLocked:
                return .keychainLocked
            case .token(let token):
                switch CursorAccessToken.state(of: token, now: now) {
                case .missing:
                    return .noToken
                case .expired:
                    return .expired(nil)
                case .present:
                    guard let response = await send(token) else { return .failed(nil) }
                    let plain: Data
                    switch CursorDashboardAuth.decodedBody(response) {
                    case .failure(let message):
                        let rejection = CursorServerRejection(
                            statusCode: response.statusCode,
                            serverMessage: message
                        )
                        CursorDashboardAuth.recordRejection(rejection)
                        if response.statusCode == 401 || response.statusCode == 403 {
                            return .expired(rejection)
                        }
                        return .failed(rejection)
                    case .success(let data):
                        plain = data
                    }
                    let visible = CursorHTTPResponse(
                        statusCode: response.statusCode,
                        body: plain,
                        contentType: response.contentType
                    )
                    if visible.statusCode == 401 || visible.statusCode == 403 {
                        let rejection = CursorDashboardAuth.loggedRejection(visible, token: token)
                        guard allowReread else { return .expired(rejection) }
                        let refreshed = await opened(await load(force: true))
                        switch refreshed {
                        case .timedOut:
                            // The server already rejected the token we sent.
                            return .expired(rejection)
                        case .missing:
                            return .noToken
                        case .keychainDenied:
                            return .keychainDenied
                        case .keychainMissing:
                            return .keychainMissing
                        case .keychainLocked:
                            return .keychainLocked
                        case .token(let newToken):
                            if newToken == token {
                                return .expired(rejection)
                            }
                            return await finish(.token(newToken), allowReread: false)
                        }
                    }
                    guard (200..<300).contains(visible.statusCode) else {
                        return .failed(CursorDashboardAuth.loggedRejection(visible, token: token))
                    }
                    guard let json = CursorDashboardAuth.usageJSON(method: method, body: visible.body) else {
                        let rejection = CursorServerRejection(
                            statusCode: visible.statusCode,
                            serverMessage: "Cursor returned a usage body this app could not read."
                        )
                        CursorDashboardAuth.recordRejection(rejection)
                        return .failed(rejection)
                    }
                    if CursorAccessToken.payloadRejectsSignIn(json) {
                        let rejection = CursorServerRejection(
                            statusCode: visible.statusCode,
                            serverMessage: CursorDashboardAuth.serverMessage(from: json, token: token)
                        )
                        CursorDashboardAuth.recordRejection(rejection)
                        return .expired(rejection)
                    }
                    return .success(json)
                }
            }
        }

        return await finish(await opened(await load(force: false)), allowReread: true)
    }

    private static func dashboardHTTP(method: String, token: String) async -> CursorHTTPResponse? {
        let profile = CursorDashboardAuth.profile(
            storageFile: CursorStateStore.storageJSON(),
            productFiles: CursorStateStore.cursorProductJSONFiles()
        )
        let request = CursorDashboardAuth.urlRequest(
            method: method,
            token: token,
            profile: profile
        )
        #if canImport(Network)
        return await CursorHTTP1Transport.send(request)
        #else
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        return CursorHTTPResponse(
            statusCode: http.statusCode,
            body: data,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            contentEncoding: http.value(forHTTPHeaderField: "Content-Encoding")
        )
        #endif
    }
}

#if canImport(Network)
/// DashboardService in Cursor 3.27.6 uses Node `https.request` (HTTP/1.1).
/// URLSession negotiates HTTP/2, so this speaks TLS with ALPN `http/1.1` only.
private enum CursorHTTP1Transport {
    static func send(_ request: URLRequest) async -> CursorHTTPResponse? {
        guard let url = request.url, let host = url.host else { return nil }
        let payload = CursorDashboardAuth.http1Message(for: request)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        guard let port = NWEndpoint.Port(rawValue: 443) else { return nil }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: NWParameters(tls: tls)
        )
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 20
        let box = HTTP1Box()
        return await withCheckedContinuation { continuation in
            box.continuation = continuation
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if error != nil {
                            box.finish(nil, connection)
                            return
                        }
                        receive(connection, Data(), box)
                    })
                case .failed, .cancelled:
                    box.finish(nil, connection)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                box.finish(nil, connection)
            }
        }
    }

    private static func receive(_ connection: NWConnection, _ accumulated: Data, _ box: HTTP1Box) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var next = accumulated
            if let data { next.append(data) }
            if next.count > 2_000_000 {
                box.finish(nil, connection)
                return
            }
            if CursorDashboardAuth.http1MessageIsComplete(next) {
                box.finish(CursorDashboardAuth.parseHTTP1(next), connection)
                return
            }
            if isComplete || error != nil {
                box.finish(CursorDashboardAuth.parseHTTP1(next), connection)
                return
            }
            receive(connection, next, box)
        }
    }
}

private final class HTTP1Box: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    var continuation: CheckedContinuation<CursorHTTPResponse?, Never>?

    func finish(_ value: CursorHTTPResponse?, _ connection: NWConnection) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        connection.cancel()
        continuation?.resume(returning: value)
    }
}
#endif

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
